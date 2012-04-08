# This will build nimrod using the specified settings.
import
  osproc, json, sockets, asyncio, os, streams, parsecfg, parseopt, strutils,
  ftpclient, times
import types

const
  builderVer = "0.1"
  buildReadme = """
This is a minimal distribution of the Nimrod compiler. Full source code can be
found at http://github.com/Araq/Nimrod
"""
  webFP = {fpUserRead, fpUserWrite, fpUserExec,
           fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec}

type
  TCurrentProc = enum
    unstage, pullProc,
    clean, unzipCSources, buildSh, ## Compiling from C Sources
    compileKoch, bootNimDebug, bootNim, ## Bootstrapping
    zipNim, # archive
    uploadNim, # FTP Upload
    runTests, # Testing
    uploadTests, # FTP Upload #2
    runDocGen, # Doc gen
    runCSrcGen, zipCSrc, # csource gen
    uploadLogs, # FTP Upload #3
    noJob # FINISHED

  TProgress = object
    currentProc: TCurrentProc
    p: PProcess
    outPipe: PStream
    payload: PJsonNode
    commitFile: TFile

  TState = object of TObject
    dispatcher: PDispatcher
    sock: PAsyncSocket
    status: TStatus ## Outcome of the build
    progress: TProgress ## Current progress
    ftp: PAsyncFTPClient
    skipCSource: bool ## Skip the process of building csources
    nimLoc: string ## Location of the nimrod repo
    websiteLoc: string ## Location of the website.
    logLoc: string ## Location of the logs for this module.
    logFile: TFile
    zipLoc: string ## Location of where to copy the files for zipping.
    docgen: bool ## Determines whether to generate docs.
    csourceGen: bool ## Determines whether to generate csources.
    platform: string
    hubAddr: string
    hubPort: int
    hubPass: string
    
    ftpUser: string
    ftpPass: string
    ftpUploadDir: string
  
    requestNewest: bool

    lastMsgTime: float ## The last time a message was received from the hub.
    pinged: float
    reconnecting: bool
  
    processThread: TThread[void]
  
  PState = ref TState

  TProcessStartInfo = tuple[p: PProcess, o: PStream]

  TPDType = enum
    TPDLine, TPDExit

  TProcessData = object
    case typ: TPDType
    of TPDLine:
      line: string
    of TPDExit:
      code: int

var
  processInfoChan: TChannel[PProcess]
  processOutputChan: TChannel[TProcessData]
processInfoChan.open()
processOutputChan.open()

# Configuration
proc parseConfig(state: PState, path: string) =
  var f = newFileStream(path, fmRead)
  if f != nil:
    var p: TCfgParser
    open(p, f, path)
    var count = 0
    while True:
      var n = next(p)
      case n.kind
      of cfgEof:
        break
      of cfgSectionStart:
        raise newException(EInvalidValue, "Unknown section: " & n.section)
      of cfgKeyValuePair, cfgOption:
        case normalize(n.key)
        of "platform":
          state.platform = n.value
          inc(count)
          # TODO: Make sure there are no ':' present in platform.
        of "nimgitpath":
          state.nimLoc = n.value
          inc(count)
        of "websitepath":
          state.websiteLoc = n.value
          inc(count)
        of "logfilepath":
          state.logLoc = n.value
          inc(count)
        of "archivepath":
          state.zipLoc = n.value
          inc(count)
        of "docgen":
          state.docgen = if normalize(n.value) == "true": true else: false
        of "csourcegen":
          state.csourceGen = if normalize(n.value) == "true": true else: false
        of "hubaddr":
          state.hubAddr = n.value
          inc(count)
        of "hubport":
          state.hubPort = parseInt(n.value)
          inc(count)
        of "hubpass":
          state.hubPass = n.value
        of "ftpuser":
          state.ftpUser = n.value
        of "ftppass":
          state.ftpPass = n.value
        of "ftpuploaddir":
          state.ftpUploadDir = n.value
        of "requestnewest":
          state.requestNewest =
            if normalize(n.value) == "true": true else: false
      of cfgError:
        raise newException(EInvalidValue, "Configuration parse error: " & n.msg)
    if count < 7:
      quit("Not all settings have been specified in the .ini file", quitFailure)
    if state.ftpUser != "" and state.ftpPass == "":
      quit("When ftpUser is specified so must the ftpPass.")

    close(p)
  else:
    quit("Cannot open configuration file: " & path, quitFailure)

proc defaultState(): PState =
  new(result)
  result.hubAddr = "127.0.0.1"
  result.hubPass = ""

  result.ftpUser = ""
  result.ftpPass = ""

  result.lastMsgTime = epochTime()
  result.pinged = -1.0
  
  result.progress.currentProc = noJob

# Build of Nimrod/tests/docs gen
proc buildFailed(state: PState, desc: string) =
  state.status.status = sBuildFailure
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sBuildFailure))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)
  
  state.sock.send($obj & "\c\L")
  echo(desc)

proc buildProgressing(state: PState, desc: string) =
  state.status.status = sBuildInProgress
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sBuildInProgress))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)
  
  state.sock.send($obj & "\c\L")
  echo(desc)

proc buildSucceeded(state: PState) =
  state.status.status = sBuildSuccess
  var obj = newJObject()
  obj["status"] = newJInt(int(sBuildSuccess))
  obj["hash"] = newJString(state.progress.payload["after"].str)

  state.sock.send($obj & "\c\L")
  echo("Build successfully completed")

proc testingFailed(state: PState, desc: string) =
  state.status.status = sTestFailure
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sTestFailure))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)

  state.sock.send($obj & "\c\L")
  echo(desc)

proc testProgressing(state: PState, desc: string) =
  state.status.status = sTestInProgress
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sTestInProgress))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)
 
  state.sock.send($obj & "\c\L")
  echo(desc)

proc testSucceeded(state: PState, total, passed,
                   skipped, failed: biggestInt) =
  state.status.status = sTestSuccess
  var obj = newJObject()
  obj["status"] = newJInt(int(sTestSuccess))
  obj["hash"] = newJString(state.progress.payload["after"].str)
  obj["total"] = newJString($total)
  obj["passed"] = newJString($passed)
  obj["skipped"] = newJString($skipped)
  obj["failed"] = newJString($failed)

  state.sock.send($obj & "\c\L")
  echo("Tests completed")

proc docGenProgressing(state: PState, desc: string) =
  state.status.status = sDocGenInProgress
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sDocGenInProgress))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)
 
  state.sock.send($obj & "\c\L")
  echo(desc)

proc docGenFailed(state: PState, desc: string) =
  state.status.status = sDocGenFailure
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sDocGenFailure))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)
 
  state.sock.send($obj & "\c\L")
  echo(desc)

proc docGenSucceeded(state: PState) =
  state.status.status = sDocGenSuccess
  var obj = newJObject()
  obj["status"] = newJInt(int(sDocGenSuccess))
  obj["hash"] = newJString(state.progress.payload["after"].str)
 
  state.sock.send($obj & "\c\L")
  echo("Doc gen success")

proc cSrcGenProgressing(state: PState, desc: string) =
  state.status.status = sCSrcGenInProgress
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sCSrcGenInProgress))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)
 
  state.sock.send($obj & "\c\L")
  echo(desc)

proc cSrcGenFailed(state: PState, desc: string) =
  state.status.status = sCSrcGenFailure
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sCSrcGenFailure))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)
 
  state.sock.send($obj & "\c\L")
  echo(desc)

proc cSrcGenSucceeded(state: PState) =
  state.status.status = sCSrcGenSuccess
  var obj = newJObject()
  obj["status"] = newJInt(int(sCSrcGenSuccess))
  obj["hash"] = newJString(state.progress.payload["after"].str)
 
  state.sock.send($obj & "\c\L")
  echo("csource gen success")

proc startMyProcess(state: PState, cmd, workDir: string,
                    args: openarray[string]): PProcess =
  if isAbsolute(cmd):
    result = startProcess(cmd.changeFileExt(ExeExt), workDir, args, nil)
  else:
    result = startProcess(workDir / cmd.changeFileExt(ExeExt), workDir,
                          args, nil)
  state.progress.outPipe = result.outputStream
  processInfoChan.send(result)

proc dCopyFile(src, dest: string) =
  echo("[INFO] Copying ", src, " to ", dest)
  copyFile(src, dest)

proc dMoveFile(src, dest: string) =
  echo("[INFO] Moving ", src, " to ", dest)
  copyFile(src, dest)
  removeFile(src)

proc dCopyDir(src, dest: string) =
  echo("[INFO] Copying directory ", src, " to ", dest)
  copyDir(src, dest)

proc dCreateDir(s: string) =
  echo("[INFO] Creating directory ", s)
  createDir(s)

proc dMoveDir(s: string, s1: string) =
  echo("[INFO] Moving directory ", s, " to ", s1)
  copyDir(s, s1)
  removeDir(s)

proc dRemoveDir(s: string) =
  echo("[INFO] Removing directory ", s)
  removeDir(s)

proc copyForArchive(nimLoc, dest: string) =
  dCreateDir(dest / "bin")
  var nimBin = "bin" / addFileExt("nimrod", ExeExt)
  dCopyFile(nimLoc / nimBin, dest / nimBin)
  dCopyFile(nimLoc / "readme.txt", dest / "readme.txt")
  dCopyFile(nimLoc / "copying.txt", dest / "copying.txt")
  dCopyFile(nimLoc / "gpl.html", dest / "gpl.html")
  writeFile(dest / "readme2.txt", buildReadme)
  dCopyDir(nimLoc / "config", dest / "config")
  dCopyDir(nimLoc / "lib", dest / "lib")

# TODO: Make this a template?
proc tally3(obj: PJsonNode, name: string,
            total, passed, skipped: var biggestInt) =
  total = total + obj[name]["total"].num
  passed = passed + obj[name]["passed"].num
  skipped = skipped + obj[name]["skipped"].num

proc tallyTestResults(path: string):
    tuple[total, passed, skipped, failed: biggestInt] =
  var f = readFile(path)
  var obj = parseJson(f)
  var total: biggestInt = 0
  var passed: biggestInt = 0
  var skipped: biggestInt = 0
  tally3(obj, "reject", total, passed, skipped)
  tally3(obj, "compile", total, passed, skipped)
  tally3(obj, "run", total, passed, skipped)
  
  return (total, passed, skipped, total - (passed + skipped))

proc isProcess(currentProc: TCurrentProc): bool =
  return currentProc notin {uploadNim, uploadTests, uploadLogs, noJob}

proc stopBuild(state: PState) =
  ## Terminates a build
  # TODO: Send a message to the website, make it record it to the database
  # as "terminated".
  
  # Simply terminate the currently running process, should hopefully work.
  if isProcess(state.progress.currentProc):
    echo("Stopping current build in progress.")
    state.progress.p.terminate()

proc beginBuild(state: PState) =
  ## This procedure starts the process of building nimrod. All it does
  ## is create a ``progress`` object, call ``buildProgressing()``,
  ## execute the ``git checkout .`` command and open a commit specific log file.
  
  # First make sure to stop any currently running process.
  state.stopBuild()
  
  var commitHash = state.progress.payload["after"].str
  var folderName = makeCommitPath(state.platform, commitHash)
  dCreateDir(state.websiteLoc / "commits" / folderName)
  var logFile    = state.websiteLoc / "commits" / folderName / "log.txt"
  state.progress.commitFile = open(logFile, fmAppend)
  
  state.progress.currentProc = unstage
  state.progress.p = state.startMyProcess(findExe("git"), state.nimLoc,
                                    "checkout", ".")
  state.buildProgressing("Unstaging changes.")


proc nextStage(state: PState)
proc setUploadLogs(state: PState) =
  state.progress.currentProc = uploadLogs

  # Upload the log.txt file
  if state.hubAddr != "127.0.0.1":
    state.ftp[].connect()
    assert state.ftp[].pwd().startsWith("/home/nimrod")
    var commitHash = state.progress.payload["after"].str
    var folderName = makeCommitPath(state.platform, commitHash)
    try:
      state.ftp[].cd(state.ftpUploadDir / "commits" / folderName)
    except EInvalidReply:
      # Create `folderName`. This is for if the bootstrap fails, and doesn't
      # get to the ftp portion, resulting in this folder not being created.
      state.ftp[].cd(state.ftpUploadDir / "commits")
      state.ftp[].createDir(folderName, true)
      state.ftp[].chmod(folderName, webFP)
      state.ftp[].cd(folderName)
      
    echo("Uploading log.txt")
    state.ftp[].store(state.websiteLoc / "commits" /
              folderName / "log.txt", "log.txt", async = true)
  else:
    echo("Local builder, no need to upload logs. Build complete.")
    state.nextStage()

proc nextStage(state: PState) =
  case state.progress.currentProc
  of unstage:
    state.progress.currentProc = pullProc
    state.progress.p = state.startMyProcess(findExe("git"),
                         state.nimLoc, "pull")
    state.buildProgressing("Executing the git pull command.")
  of pullProc:
    if not state.skipCSource:
      state.progress.currentProc = clean
      state.progress.p = state.startMyProcess("koch",
          state.nimLoc, "clean")
      state.buildProgressing("Executing koch clean")
    else:
      # Same code as in ``of buildSh:``
      state.progress.currentProc = compileKoch
      state.progress.p = state.startMyProcess("bin" / "nimrod",
          state.nimLoc, "c", "koch.nim")
      state.buildProgressing("Compiling koch.nim")
  of clean:
    state.progress.currentProc = unzipCSources
    when defined(windows):
      state.progress.p = state.startMyProcess(findExe("7za"),
          state.nimLoc / "build", "e", "csources.zip",
          "-o" & state.nimLoc / "build")
      state.buildProgressing("Executing 7za e")
    else:
      state.progress.p = state.startMyProcess(findExe("unzip"),
          state.nimLoc / "build", "csources.zip")
      state.buildProgressing("Executing unzip")
  of unzipCSources:
    state.progress.currentProc = buildSh
    state.progress.p = state.startMyProcess(findExe("sh"),
        state.nimLoc, "build.sh")
    state.buildProgressing("Compiling C sources")
  of buildSh:
    state.progress.currentProc = compileKoch
    state.progress.p = state.startMyProcess("bin" / "nimrod",
        state.nimLoc, "c", "koch.nim")
    state.buildProgressing("Compiling koch.nim")
  of compileKoch:
    state.progress.currentProc = bootNimDebug
    state.progress.p = state.startMyProcess("koch",
        state.nimLoc, "boot")
    state.buildProgressing("Bootstrapping Nimrod")
  of bootNimDebug:
    state.progress.currentProc = bootNim
    state.progress.p = state.startMyProcess("koch",
        state.nimLoc, "boot", "-d:release")
    state.buildProgressing("Bootstrapping Nimrod in release mode")
  of bootNim:
    var commitHash = state.progress.payload["after"].str
    var folderName = makeCommitPath(state.platform, commitHash)
    var dir = state.zipLoc / folderName
    var zipFile = addFileExt(folderName, "zip")
    
    dCreateDir(dir)
    # TODO: This will block :(
    copyForArchive(state.nimLoc, dir)
    
    # Remove the .zip in case it already exists...
    if existsFile(state.zipLoc / zipFile): removeFile(state.zipLoc / zipFile)
    state.progress.currentProc = zipNim
    when defined(windows):
      state.progress.p = state.startMyProcess(findexe("7za"),
                state.zipLoc, "a", "-tzip", zipFile.extractFilename, folderName)
    else:
      state.progress.p = state.startMyProcess(findexe("zip"),
          state.zipLoc, "-r", zipFile, folderName)
    state.buildProgressing("Creating archive - zip")
  
  of zipNim:
    # Copy the .zip file
    var commitHash = state.progress.payload["after"].str
    var fileName = makeCommitPath(state.platform, commitHash)
    var zip = addFileExt(fileName, "zip")
    var saveAs = addFileExt(makeZipPath(state.platform, commitHash), "zip")
    # Remove the pre-zipped folder with the binaries.
    dRemoveDir(state.zipLoc / fileName)
    when defined(windows):
      dMoveFile(state.zipLoc / zip.extractFilename,
                state.websiteLoc / "commits" / saveAs)
    else:
      dMoveFile(state.zipLoc / zip, state.websiteLoc / "commits" / saveAs)
   
    # --- FTP file upload, for binaries. ---
    state.progress.currentProc = uploadNim
    if state.hubAddr != "127.0.0.1":
      state.ftp[].connect()
      assert state.ftp[].pwd().startsWith("/home/nimrod")
      state.ftp[].cd(state.ftpUploadDir / "commits")
      
      try: state.ftp[].createDir(fileName, true)
      except EInvalidReply: nil # TODO: Check properly whether the folder exists
      
      state.ftp[].chmod(fileName, webFP)
      state.ftp[].store(state.websiteLoc / "commits" / saveAs, saveAs,
                      async = true)
      state.buildProgressing("Uploading files...")
    else: state.nextStage()
  
  of uploadNim:
    # Files uploaded. Success.
    buildSucceeded(state)
  
    # --- Start of tests ---
    
    # Start test suite!
    state.progress.currentProc = runTests
    state.progress.p = state.startMyProcess("koch", state.nimLoc, "tests")
    testProgressing(state, "Testing nimrod build...")
    
  of runTests:
    # Copy the testresults.html file.
    var commitHash = state.progress.payload["after"].str
    var folderName = makeCommitPath(state.platform, commitHash)
    #dCreateDir(state.websiteLoc / "commits" / folderName)
    setFilePermissions(state.websiteLoc / "commits" / folderName,
                       webFP)
                        
    dCopyFile(state.nimLoc / "testresults.html",
              state.websiteLoc / "commits" / folderName / "testresults.html")
    
    # --- FTP file upload, for binaries. ---
    state.progress.currentProc = uploadTests
    if state.hubAddr != "127.0.0.1":
      state.ftp[].connect()
      assert state.ftp[].pwd().startsWith("/home/nimrod")
      state.ftp[].cd(state.ftpUploadDir / "commits" / folderName)
      state.ftp[].store(state.websiteLoc / "commits" /
                      folderName / "testresults.html", "testresults.html",
                      async = true)
      testProgressing(state, "Uploading test results.")
    else: state.nextStage()
      
  of uploadTests:
    var (total, passed, skipped, failed) =
        tallyTestResults(state.nimLoc / "testresults.json")
    testSucceeded(state, total, passed, skipped, failed)
    # TODO: Copy testresults.json too?
    
    # --- Start of doc gen ---
    # Create the upload directory and the docs directory on the website
    state.progress.currentProc = runDocGen
    if state.docgen:
      dCreateDir(state.nimLoc / "web" / "upload")
      dCreateDir(state.websiteLoc / "docs")
      state.progress.p = state.startMyProcess("koch",
                state.nimLoc, "web")
      docgenProgressing(state, "Running koch web...")
    else:
      state.nextStage() # Skip this stage.

  of runDocGen:
    if state.docGen:
      # Copy all the docs to the website.
      dCopyDir(state.nimLoc / "web" / "upload", state.websiteLoc / "docs")
    
      docgenSucceeded(state)
  
    # --- Start of csources gen ---
    if state.csourceGen:
      # Rename the build directory so that the csources from the git repo aren't
      # overwritten
      dMoveDir(state.nimLoc / "build", state.nimLoc / "build_old")
      dCreateDir(state.nimLoc / "build")

      state.progress.currentProc = runCSrcGen
      state.progress.p = state.startMyProcess("koch",
          state.nimLoc, "csource")
      state.cSrcGenProgressing("Running `koch csource`")
    else:
      state.setUploadLogs() # Skip the rest, and move onto the upload of log.txt

  of runCSrcGen:
    # Zip up the csources.
    # -- Move the build directory to the zip location
    var commitHash = state.progress.payload["after"].str
    var folderName = makeCommitPath(state.platform, commitHash)
    folderName.add("_csources")
    var zipFile = folderName.addFileExt("zip")
    dMoveDir(state.nimLoc / "build", state.zipLoc / folderName / "build")
    # -- Move `build_old` to where it was.
    dMoveDir(state.nimLoc / "build_old", state.nimLoc / "build")
    # -- Copy build.sh and build.bat.
    dCopyFile(state.nimLoc / "build.sh", state.zipLoc / folderName /
               "build.sh")
    dCopyFile(state.nimLoc / "build.bat", state.zipLoc / folderName /
               "build.bat")
    # -- License
    dCopyFile(state.nimLoc / "copying.txt",
              state.zipLoc / folderName / "copying.txt")
    dCopyFile(state.nimLoc / "gpl.html",
              state.zipLoc / folderName / "gpl.html")
    writeFile(state.zipLoc / folderName / "readme2.txt", buildReadme)
    # -- ZIP!
    if existsFile(state.zipLoc / zipFile): removeFile(state.zipLoc / zipFile)
    state.progress.currentProc = zipCSrc
    when defined(windows):
      echo("Not implemented")
      doAssert(false)
    state.progress.p = state.startMyProcess(findexe("zip"),
        state.zipLoc, "-r", zipFile, folderName)
    state.cSrcGenProgressing("Creating csource archive")

  of zipCSrc:
    # Copy the .zip file
    var commitHash = state.progress.payload["after"].str
    var folderName = makeCommitPath(state.platform, commitHash)
    folderName.add("_csources")
    var saveAs = makeZipPath(state.platform, commitHash)
    saveAs.add("_csources")
    saveAs = saveAs.addFileExt("zip")

    # Remove the pre-zipped folder with the C sources.
    dRemoveDir(state.zipLoc / folderName)
    var zip = folderName.addFileExt("zip")
    dMoveFile(state.zipLoc / zip, state.websiteLoc / "commits" / saveAs)

    state.cSrcGenSucceeded()
    
    state.setUploadLogs()

  of uploadLogs:
    echo("Builder done.")
    state.progress.currentProc = noJob

  of noJob: assert(false)

proc readAll(p: PProcess, s: PStream): string =
  result = "" 
  var ps: seq[PProcess] = @[]
  while True:
    ps = @[p]
    if select(ps, 10) != 1: return
    var c = s.readChar()
    if c == '\0': break
    result.add(c)

proc readAllBlock(s: PStream): string =
  result = ""
  while True:
    var c = s.readChar()
    if c == '\0': break
    result.add(c)

proc writeLogs(logFile, commitFile: TFile, s: string) =
  logFile.write(s)
  logFile.flushFile()
  commitFile.write(s)
  commitFile.flushFile()

proc readProcess(){.thread.} =
  # This thread proc will attempt to read data from a process.
  # This is needed because async process reading is quite hard to accomplish,
  # especially on Windows.
  var p: PProcess
  var o: PStream
  var started = false
  while True:
    var tasks = processInfoChan.peek()
    if tasks == 0 and not started: tasks = 1
    if tasks > 0:
      p = processInfoChan.recv()
      if not started:
        if processOutputChan.peek() != 0:
          for i in 0..processOutputChan.peek()-1:
            discard processOutputChan.recv()
        assert(processOutputChan.peek() == 0)
        started = true
        o = p.outputStream
        echo("[Thread] Process started.")
      else: 
        echo("[Thread] Process still running.")
        assert(false)
    
    if started:
      var line = o.readLine()
      var dat: TProcessData
      if line != "":
        dat.typ = TPDLine
        dat.line = line & "\n"
        processOutputChan.send(dat)
      else:
        var code = p.peekExitCode()
        if code == -1:
          echo("[Thread] Process is still apparently running.")
        else:
          echo("[Thread] Process exited.")
          o.close()
          p.close()
          started = false
          dat.typ = TPDExit
          dat.code = code
          processOutputChan.send(dat)
    
    # Check to make sure that the process hasn't already exited.
    # This should prevent cases where the channel receives 2 TPDExit
    # messages.
    if started:
      var peekedExit = p.peekExitCode()
      if peekedExit != -1:
        echo("[Thread] Caught process exit outside.")
        started = false
        o.close()
        p.close()
        var dat: TProcessData
        dat.typ = TPDExit
        dat.code = peekedExit
        processOutputChan.send(dat)
          
proc checkProgress(state: PState) =
  ## This is called from the main loop - checks the progress of the current
  ## process being run as part of the build/test process.
  if isInProgress(state.status.status) and 
     isProcess(state.progress.currentProc):
    var lines = processOutputChan.peek()
    if lines > 0:
      for i in 0..lines-1:
        var dat = processOutputChan.recv()
        case dat.typ
        of TPDLine:
          #echo(state.progress.currentProc, " output: ", line.len)
          
          writeLogs(state.logFile, state.progress.commitFile, dat.line)
        of TPDExit:
          var exitCode = dat.code
          echo(state.progress.currentProc, " terminated")
          
          if exitCode == QuitSuccess:
            var s = $state.progress.currentProc & " finished successfully."
            writeLogs(state.logFile, state.progress.commitFile, s & "\n")
            echo(state.progress.currentProc,
                 " exited successfully. Continuing to next stage.")
            state.nextStage()
            s = $state.progress.currentProc & " started."
            writeLogs(state.logFile, state.progress.commitFile, s & "\n")
          else:
            if state.progress.currentProc <= zipNim:
              echo(state.progress.currentProc,
                   " failed. Build failed! Exit code = ", exitCode)
              buildFailed(state, $state.progress.currentProc &
                          " failed with exit code 1")
            elif state.progress.currentProc <= runTests:
              echo(state.progress.currentProc,
                   " failed. Running tests failed! Exit code = ", exitCode)
              testingFailed(state, $state.progress.currentProc &
                            " failed with exit code 1")
            elif state.progress.currentProc <= runDocGen:
              echo(state.progress.currentProc,
                   " failed. Generating docs failed! Exit code = ", exitCode)
              docgenFailed(state, $state.progress.currentProc &
                            " failed with exit code 1")
            elif state.progress.currentProc <= zipCSrc:
              echo(state.progress.currentProc,
                   " failed. Generating csources failed! Exit code = ", exitCode)
              cSrcGenFailed(state, $state.progress.currentProc &
                            " failed with exit code 1")
           
            state.setUploadLogs()

# Communication
proc parseReply(line: string, expect: string): Bool =
  var jsonDoc = parseJson(line)
  return jsonDoc["reply"].str == expect

proc hubConnect(state: PState, reconnect: bool)
proc handleConnect(s: PAsyncSocket, userArg: PObject) =
  var state = PState(userArg)
  try:
    # Send greeting
    var obj = newJObject()
    obj["name"] = newJString("builder")
    obj["platform"] = newJString(state.platform)
    if state.hubPass != "": obj["pass"] = newJString(state.hubPass)
    state.sock.send($obj & "\c\L")
    # Wait for reply.
    var readSocks = @[state.sock.getSocket]
    # TODO: Don't use select here. Just sleep(1500). Then readLine.
    if select(readSocks, 1500) == 1 and readSocks.len == 0:
      var line = ""
      if not state.sock.recvLine(line):
        raise newException(EInvalidValue, "recvLine failed.")
      if not parseReply(line, "OK"):
        raise newException(EInvalidValue, "Incorrect welcome message from hub") 
      
      echo("The hub accepted me!")

      if state.requestNewest and not state.reconnecting:
        echo("Requesting newest commit.")
        var req = newJObject()
        req["latestCommit"] = newJNull()
        state.sock.send($req & "\c\L")

    else:
      raise newException(EInvalidValue,
                         "Hub didn't accept me. Waited 1.5 seconds.")
  except EOS, EInvalidValue:
    echo(getCurrentExceptionMsg())
    s.close()
    echo("Waiting 5 seconds...")
    sleep(5000)
    try: hubConnect(state, true) except EOS: echo(getCurrentExceptionMsg()) 

proc handleHubMessage(s: PAsyncSocket, userArg: PObject)
proc hubConnect(state: PState, reconnect: bool) =
  state.sock = AsyncSocket(userArg = state)
  state.sock.handleConnect = handleConnect
  state.sock.handleRead = handleHubMessage
  state.reconnecting = reconnect
  state.sock.connect(state.hubAddr, TPort(state.hubPort))
  state.dispatcher.register(state.sock)

proc handleFtp(ftp: var TAsyncFTPClient, ev: TFTPEvent, userArg: PObject) =
  var state = PState(userArg)
  assert(state.progress.currentProc in {uploadNim, uploadTests, uploadLogs})
  if state.hubAddr != "127.0.0.1":
    case ev.typ
    of EvStore:
      echo("Upload of ", ev.filename,
           " complete. Continuing to next stage.")
      var path = state.ftpUploadDir /
                 ev.filename[state.websiteLoc.len().. -1]
      echo("Changing permissions for ", path)
      state.ftp[].chmod(path, webFP)

      state.ftp[].close()
      state.nextStage()
    of EvTransferProgress:
      # TODO: Output this less often.
      echo(ev.speed div 1000, " kb/s")
    else: assert(false)
  else: assert(false)

proc open(configPath: string): PState =
  result = defaultState()
  # Get config
  parseConfig(result, configPath)
  if not existsDir(result.nimLoc):
    quit(result.nimLoc & " does not exist!", quitFailure)
  
  # Init dispatcher
  result.dispatcher = newDispatcher()
  
  # Connect to the hub
  result.hubConnect(false)

  # Open log file
  result.logFile = open(result.logLoc, fmAppend)
  
  # Init status
  result.status = initStatus()

  # Init ftp client.
  if result.hubAddr != "127.0.0.1":
    result.ftp = AsyncFTPClient(result.hubAddr,
                          user = result.ftpUser, pass = result.ftpPass,
                          userArg = result)
    result.ftp.handleEvent = handleFtp
    result.dispatcher.register(result.ftp)

proc fileInModified(json: PJsonNode, file: string): bool =
  for commit in items(json["commits"].elems):
    for f in items(commit["modified"].elems):
      if f.str == file: return true

proc parseMessage(state: PState, line: string) =
  echo("Got message from hub: ", line)
  state.lastMsgTime = epochTime()
  var json = parseJson(line)
  if json.existsKey("payload"):
    if json["rebuild"].bval:
      # This commit has already been built. We don't get a full payload as
      # it is not stored.
      # Because the build process on depends on "after" that is all that is
      # needed.
      assert(json["payload"].existsKey("after"))
      state.skipCSource = true
      state.progress.payload = json["payload"]
      echo("Re-bootstrapping!")
      state.beginBuild()
    else:
      # This should be a message from the "github" module
      # The payload object should have a `after` string.
      assert(json["payload"].existsKey("after"))
      state.skipCSource = not fileInModified(json["payload"],
                                             "build/csources.zip")
      state.progress.payload = json["payload"]
      echo("Bootstrapping!")
      state.beginBuild()

  elif json.existsKey("ping"):
    # Website is making sure that the connection is alive.
    # All we do is change the "ping" to "pong" and reply.
    json["pong"] = json["ping"]
    json.delete("ping")
    state.sock.send($json & "\c\L")
    echo("Replying to Ping")
 
  elif json.existsKey("pong"):
    # Website replied. Connection is still alive.
    state.pinged = -1.0
    echo("Hub replied to PING. Still connected")

proc hubDisconnect(state: PState) =
  state.sock.close()

  state.lastMsgTime = epochTime()
  state.pinged = -1.0

proc reconnect(state: PState) =
  state.hubDisconnect()
  try: state.hubConnect(true)
  except EOS:
    echo(getCurrentExceptionMsg())

proc handleHubMessage(s: PAsyncSocket, userArg: PObject) =
  var state = PState(userArg)
  var line = ""
  if state.sock.recvLine(line):
    if line != "":
      state.parseMessage(line)
    else:
      echo("Disconnected from hub: ", OSErrorMsg())
      reconnect(state)
  else:
    echo(OSErrorMsg())

proc checkTimeout(state: PState) =
  const timeoutSeconds = 110.0

  if state.hubAddr != "127.0.0.1":
    # Check how long ago the last message was sent.
    if state.pinged == -1.0:
      if epochTime() - state.lastMsgTime >= timeoutSeconds:
        echo("We seem to be timing out! PINGing server.")
        var jsonObject = newJObject()
        jsonObject["ping"] = newJString(formatFloat(epochTime()))
        try:
          state.sock.send($jsonObject & "\c\L")
        except EOS:
          echo(OSErrorMsg())
          echo("Disconnected from server due to ^^")
          reconnect(state)
          return
          
        state.pinged = epochTime()

    else:
      if epochTime() - state.pinged >= 5.0: # 5 seconds
        echo("Server has not replied with a pong in 5 seconds.")
        # TODO: What happens if the builder gets disconnected in the middle of a
        # build? Maybe implement restoration of that.
        reconnect(state)

proc showHelp() =
  const help = """Usage: builder [options] configFile
    -h  --help    Show this help message
    -v  --version Show version  
  """
  quit(help, quitSuccess)

proc showVersion() =
  const version = """builder $1 - built on $2
This software is part of the nimbuild website."""
  quit(version % [builderVer, compileDate & " " & compileTime], quitSuccess)

proc parseArgs(): string =
  result = ""
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      result = key
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": showHelp()
      of "version", "v": showVersion()
    of cmdEnd: assert(false) # cannot happen
  if result == "":
    showHelp()

when isMainModule:
  echo("Started builder: built at ", CompileDate, " ", CompileTime)
  var state = builder.open(parseArgs())
  createThread[void](state.processThread, readProcess)
  while True:
    discard state.dispatcher.poll()
    
    state.checkProgress()
  
    state.checkTimeout()
  

