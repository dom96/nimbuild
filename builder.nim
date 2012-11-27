# This will build nimrod using the specified settings.
import
  osproc, json, sockets, asyncio, os, streams, parsecfg, parseopt, strutils,
  ftpclient, times, strtabs
import types

const
  builderVer = "0.2"
  buildReadme = """
This is a minimal distribution of the Nimrod compiler. Full source code can be
found at http://github.com/Araq/Nimrod
"""
  webFP = {fpUserRead, fpUserWrite, fpUserExec,
           fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec}

type
  TJob = object
    payload: PJsonNode
    p: PProcess ## Current process that is running.
    cmd: string
    thread: TThread[TBuildData]

  TCfg = object
    nimLoc: string ## Location of the nimrod repo
    websiteLoc: string ## Location of the website.
    logLoc: string ## Location of the logs for this module.
    zipLoc: string ## Location of where to copy the files for zipping.
    docgen: bool ## Determines whether to generate docs.
    csourceGen: bool ## Determines whether to generate csources.
    csourceExtraBuildArgs: string
    platform: string
    hubAddr: string
    hubPort: int
    hubPass: string
    
    ftpUser: string
    ftpPass: string
    ftpPort: TPort
    ftpUploadDir: string
  
    requestNewest: bool

  TState = object of TObject
    dispatcher: PDispatcher
    sock: PAsyncSocket
    building: bool
    buildJob: TJob ## Current build
    skipCSource: bool ## Skip the process of building csources
    logFile: TFile
    cfg: TCfg
    lastMsgTime: float ## The last time a message was received from the hub.
    pinged: float
    reconnecting: bool
  
  PState = ref TState

  TBuildData = object
    payload: PJsonNode
    cfg: TCfg

  TBuildProgressType = enum
    ProcessStart, ProcessExit, HubMsg, BuildEnd
  
  TBuildProgress = object ## This object gets sent to the main thread, by the builder thread.
    case kind: TBuildProgressType
    of ProcessStart:
      p: PProcess
    of ProcessExit, BuildEnd: nil
    of HubMsg:
      msg: string

  TThreadCommand = enum
    ThreadTerminate

  EBuildEnd = object of ESynch

var
  hubChan: TChannel[TBuildProgress]
  threadCommandChan: TChannel[TThreadCommand]

hubChan.open()
threadCommandChan.open()

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
          state.cfg.platform = n.value
          inc(count)
          if ':' in state.cfg.platform: quit("No ':' allowed in the platform name.")
        of "nimgitpath":
          state.cfg.nimLoc = n.value
          inc(count)
        of "websitepath":
          state.cfg.websiteLoc = n.value
          inc(count)
        of "logfilepath":
          state.cfg.logLoc = n.value
          inc(count)
        of "archivepath":
          state.cfg.zipLoc = n.value
          inc(count)
        of "docgen":
          state.cfg.docgen = if normalize(n.value) == "true": true else: false
        of "csourcegen":
          state.cfg.csourceGen = if normalize(n.value) == "true": true else: false
        of "csourceextrabuildargs":
          state.cfg.csourceExtraBuildArgs = n.value
        of "hubaddr":
          state.cfg.hubAddr = n.value
          inc(count)
        of "hubport":
          state.cfg.hubPort = parseInt(n.value)
          inc(count)
        of "hubpass":
          state.cfg.hubPass = n.value
        of "ftpuser":
          state.cfg.ftpUser = n.value
        of "ftppass":
          state.cfg.ftpPass = n.value
        of "ftpport":
          state.cfg.ftpPort = parseInt(n.value).TPort
        of "ftpuploaddir":
          state.cfg.ftpUploadDir = n.value
        of "requestnewest":
          state.cfg.requestNewest =
            if normalize(n.value) == "true": true else: false
      of cfgError:
        raise newException(EInvalidValue, "Configuration parse error: " & n.msg)
    if count < 7:
      quit("Not all settings have been specified in the .ini file", quitFailure)
    if state.cfg.ftpUser != "" and state.cfg.ftpPass == "":
      quit("When ftpUser is specified so must the ftpPass.")

    close(p)
  else:
    quit("Cannot open configuration file: " & path, quitFailure)

proc defaultState(): PState =
  new(result)
  result.cfg.hubAddr = "127.0.0.1"
  result.cfg.hubPass = ""

  result.cfg.ftpUser = ""
  result.cfg.ftpPass = ""
  result.cfg.ftpPort = TPort(21)

  result.lastMsgTime = epochTime()
  result.pinged = -1.0

  result.cfg.csourceExtraBuildArgs = ""

proc initJob(): TJob =
  result.payload = nil

# Build of Nimrod/tests/docs gen

template sendHubMsg(m: string): stmt =
  var bp: TBuildProgress
  bp.kind = HubMsg
  bp.msg = m
  hubChan.send(bp)

proc hubSendBuildStart(hash, branch: string) =
  var obj = %{"eventType": %(int(bStart)),
              "hash": %hash,
              "branch": %branch}
  sendHubMsg($obj & "\c\L")

proc hubSendProcessStart(process: PProcess, cmd, args: string) =
  var bp: TBuildProgress
  bp.kind = ProcessStart
  bp.p = process
  hubChan.send(bp)
  var obj = %{"desc": %("\"" & cmd & " " & args & "\" started."),
              "eventType": %(int(bProcessStart)),
              "cmd": %cmd,
              "args": %args}
  sendHubMsg($obj & "\c\L")

proc hubSendProcessLine(line: string) =
  var obj = %{"eventType": %(int(bProcessLine)),
              "line": %line}
  sendHubMsg($obj & "\c\L")

proc hubSendProcessExit(exitCode: int) =
  var bp: TBuildProgress
  bp.kind = ProcessExit
  hubChan.send(bp)
  var obj = %{"eventType": %(int(bProcessExit)),
              "exitCode": %exitCode}
  sendHubMsg($obj & "\c\L")

proc hubSendFTPUploadSpeed(speed: float) =
  var obj = %{"desc": %("FTP Upload at " & formatFloat(speed) & "KB/s"),
              "eventType": %(int(bFTPUploadSpeed)),
              "speed": %speed}
  sendHubMsg($obj & "\c\L")

proc hubSendJobUpdate(job: TBuilderJob) =
  var obj = %{"job": %(int(job))}
  sendHubMsg($obj & "\c\L")

proc hubSendBuildFail(msg: string) =
  var obj = %{"result": %(int(Failure)),
              "detail": %msg}
  sendHubMsg($obj & "\c\L")

proc hubSendBuildSuccess() =
  var obj = %{"result": %(int(Success))}
  sendHubMsg($obj & "\c\L")

proc hubSendBuildTestSuccess(total, passed, skipped, failed: biggestInt) =
  var obj = %{"result": %(int(Success)),
              "total": %(total),
              "passed": %(passed),
              "skipped": %(skipped),
              "failed": %(failed)}
  sendHubMsg($obj & "\c\L")

proc hubSendBuildEnd() =
  var bp: TBuildProgress
  bp.kind = BuildEnd
  hubChan.send(bp)

  var obj = %{"eventType": %(int(bEnd))}
  sendHubMsg($obj & "\c\L")

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

proc dRemoveFile(s: string) =
  echo("[INFO] Removing file ", s)
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

proc fileInModified(json: PJsonNode, file: string): bool =
  if json.existsKey("commits"):
    for commit in items(json["commits"].elems):
      for f in items(commit["modified"].elems):
        if f.str == file: return true

template buildTmpl(body: stmt): stmt =
  try:
    body
  except EBuildEnd:
    hubSendBuildFail(getCurrentExceptionMsg())
  hubSendBuildEnd()

proc hasBuildTerminated(): bool =
  ## Checks whether the main thread asked for the build to be terminated.
  result = false
  if threadCommandChan.peek() > 0:
    let thrCmd = threadCommandChan.recv()
    assert thrCmd == ThreadTerminate
    return true

proc runProcess(env: PStringTable = nil, workDir, execFile: string,
                args: openarray[string]): bool =
  ## Returns ``true`` if process finished successfully. Otherwise ``false``.
  result = true
  var cmd = ""
  if isAbsolute(execFile):
    cmd = execFile.changeFileExt(ExeExt)
  else:
    cmd = workDir / execFile.changeFileExt(ExeExt)
  var process = startProcess(cmd, workDir, args, env)
  hubSendProcessStart(process, execFile.extractFilename, join(args, " "))
  var pStdout = process.outputStream
  proc hasProcessTerminated(process: PProcess, exitCode: var int): bool =
    result = false
    exitCode = process.peekExitCode()
    if exitCode != -1:
      hubSendProcessExit(exitCode)
      return true
  var line = ""
  var exitCode = -1
  while true:
    line = ""
    if pStdout.readLine(line) and line != "":
      echo("[Thread] Process Line: ", line)
      hubSendProcessLine(line)
    if hasProcessTerminated(process, exitCode):
      break
  result = exitCode == QuitSuccess 
  echo("! " & execFile.extractFilename & " " & join(args, " ") & " exited with ", exitCode)
  pStdout.close()
  process.close()

proc changeNimrodInPATH(bindir: string): string =
  var paths = getEnv("PATH").split(pathSep)
  for i in 0 .. <paths.len:
    let noTrailing = if paths[i][paths[i].len-1] == dirSep: paths[i][0 .. -2] else: paths[i]
    if cmpPaths(noTrailing, findExe("nimrod").splitFile.dir) == 0:
      paths[i] = bindir
  return paths.join($pathSep)

proc run(env: PStringTable = nil, workDir: string, exec: string,
         args: varargs[string]) =
  echo("! " & exec.extractFilename & " " & join(args, " ") & " started.")
  if not runProcess(env, workDir, exec, args):
    raise newException(EBuildEnd,
        "\"" & exec.extractFilename & " " & join(args, " ") & "\" failed.")
  if hasBuildTerminated():
    raise newException(EBuildEnd, "Bootstrap aborted.")

proc run(workDir: string, exec: string, args: varargs[string]) =
  run(nil, workDir, exec, args)

proc setGIT(payload: PJsonNode, nimLoc: string) =
  ## Cleans working tree, changes branch and pulls.
  let branch = payload["ref"].str[11 .. -1]
  let commitHash = payload["after"].str

  run(nimLoc, findExe("git"), "checkout", ".")
  run(nimLoc, findExe("git"), "checkout", branch)
  # TODO: Capture changed files from output?
  run(nimLoc, findExe("git"), "pull")
  run(nimLoc, findExe("git"), "checkout", commitHash)

proc nimBootstrap(payload: PJsonNode, nimLoc, csourceExtraBuildArgs: string) =
  ## Set of steps to bootstrap Nimrod. In debug and release mode.
  ## Does not perform any git actions!

  # Do compile koch here if nimrod binary exists.
  # This is so that 'koch clean' can be used.
  # if the nimrod binary does not exist then it's quite unlikely that
  # koch won't be compiled /and/ we need to run koch clean.
  if ((not existsFile(nimLoc / "koch")) or 
      fileInModified(payload, "koch.nim")) and
      existsFile(nimLoc / "bin" / "nimrod"):
    run(nimLoc, "bin" / "nimrod", "c", "koch.nim")

  # skipCSource is already set to true if 'csources.zip' changed.
  # force running of ./build.sh if the nimrod binary is nonexistent.
  if fileInModified(payload, "build/csources.zip") or 
       not existsFile("bin" / "nimrod"):
    if existsFile(nimLoc / "koch"):
      run(nimLoc, "koch", "clean")
    # Unzip C Sources
    when defined(windows):
      run(nimLoc / "build", findExe("7za"), "e", "csources.zip")
    else:
      run(nimLoc / "build", findExe("unzip"), "csources.zip")
    # ./build.sh
    run(nimLoc, findExe("sh"), "build.sh", csourceExtraBuildArgs)
  
  if (not existsFile(nimLoc / "koch")) or 
      fileInModified(payload, "koch.nim"):
    run(nimLoc, "bin" / "nimrod", "c", "koch.nim")
  
  # Bootstrap!
  run(nimLoc, "koch", "boot")
  run(nimLoc, "koch", "boot", "-d:release")

proc archiveNimrod(platform, commitPath, commitHash, websiteLoc,
                   nimLoc, rootZipLoc: string): string =
  ## Zips up the build.
  ## Returns the full absolute path to where the zipped file resides.
  
  # Set +x on nimrod binary
  setFilePermissions(nimLoc / "bin" / "nimrod", webFP)
  let zipPath = rootZipLoc / commitPath
  let zipFile = addFileExt(commitPath, "zip")

  dCreateDir(zipPath)
  copyForArchive(nimLoc, zipPath)

  # Remove the .zip in case it already exists...
  if existsFile(rootZipLoc / zipFile): removeFile(rootZipLoc / zipFile)
  when defined(windows):
    run(rootZipLoc, findExe("7za"), "a", "-tzip",
        zipFile.extractFilename, commitPath)
  else:
    run(rootZipLoc, findExe("zip"), "-r", zipFile, commitPath)

  # Copy the .zip file
  var zipFinalPath = addFileExt(makeZipPath(platform, commitHash), "zip")
  # Remove the pre-zipped folder with the binaries.
  dRemoveDir(zipPath)
  # Move the .zip file to the website
  when defined(windows):
    dMoveFile(rootZipLoc / zipFile.extractFilename,
              websiteLoc / "commits" / zipFinalPath)
  else:
    dMoveFile(rootZipLoc / zipFile, websiteLoc / "commits" / zipFinalPath)
  # Remove the original .zip file
  dRemoveFile(rootZipLoc / zipFile)
  
  result = websiteLoc / "commits" / zipFinalPath

proc uploadFile(ftpAddr: string, ftpPort: TPort, user, pass, workDir,
                uploadDir, file, destFile: string) =
  
  proc handleEvent(f: PAsyncFTPClient, ev: TFTPEvent) =
    case ev.typ
    of EvStore:
      f.close()
    of EvTransferProgress:
      hubSendFTPUploadSpeed(ev.speed.float / 1024.0)
    else: assert false
  
  var ftpc = AsyncFTPClient(ftpAddr, ftpPort, user, pass, handleEvent)
  ftpc.connect()
  assert ftpc.pwd().startsWith("/home" / user) # /home/nimrod
  ftpc.cd(workDir)
  
  try: ftpc.createDir(uploadDir, true)
  except EInvalidReply: nil # TODO: Check properly whether the folder exists
  
  ftpc.chmod(uploadDir, webFP)
  var disp = newDispatcher()
  disp.register(ftpc)
  ftpc.store(file, destFile, async = true)

proc nimTest(commitPath, nimLoc, websiteLoc: string): string =
  ## Runs the tester, returns the full absolute path to where the tests
  ## have been saved.
  result = websiteLoc / "commits" / commitPath / "testresults.html"
  run(nimLoc, "koch", "tests")
  # Copy the testresults.html file.
  dCreateDir(websiteLoc / "commits" / commitPath)
  setFilePermissions(websiteLoc / "commits" / commitPath,
                     webFP)
  dCopyFile(nimLoc / "testresults.html", result)

proc bootstrapTmpl(info: TBuildData) {.thread.} =
  ## Template for a full bootstrap.
  buildTmpl:
    let cfg = info.cfg
    let commitHash = info.payload["after"].str
    let commitBranch = info.payload["ref"].str[11 .. -1]
    let commitPath = makeCommitPath(cfg.platform, commitHash)
    hubSendBuildStart(commitHash, commitBranch)
    hubSendJobUpdate(jBuild)
    
    # GIT
    setGIT(info.payload, cfg.nimLoc)
    
    # Bootstrap
    nimBootstrap(info.payload, cfg.nimLoc, cfg.csourceExtraBuildArgs)
    
    var buildZipFilePath = archiveNimrod(cfg.platform, commitPath, commitHash,
                                         cfg.websiteLoc, cfg.nimLoc, cfg.zipLoc)
    
    # --- Upload zip with build ---
    if cfg.hubAddr != "127.0.0.1":
      uploadFile(cfg.hubAddr, cfg.ftpPort, cfg.ftpUser, 
                 cfg.ftpPass,
                 cfg.ftpUploadDir / "commits", commitPath,
                 buildZipFilePath,
                 buildZipFilePath.extractFilename)

    hubSendBuildSuccess()
    hubSendJobUpdate(jTest)
    var testResultsPath = nimTest(commitPath, cfg.nimLoc, cfg.websiteLoc)
    
    # --- Upload testresults.html ---
    if cfg.hubAddr != "127.0.0.1":
      uploadFile(cfg.hubAddr, cfg.ftpPort, cfg.ftpUser,
                 cfg.ftpPass, cfg.ftpUploadDir / "commits", commitPath,
                 testResultsPath, "testresults.html")
    var (total, passed, skipped, failed) =
        tallyTestResults(cfg.nimLoc / "testresults.json")
    hubSendBuildTestSuccess(total, passed, skipped, failed)

    # --- Start of doc gen ---
    # Create the upload directory and the docs directory on the website
    if cfg.docgen:
      hubSendJobUpdate(jDocGen)
      dCreateDir(cfg.nimLoc / "web" / "upload")
      dCreateDir(cfg.websiteLoc / "docs")
      run({"PATH": changeNimrodInPATH(cfg.nimLoc / "bin")}.newStringTable(),
          cfg.nimLoc, "koch", "web")
      # Copy all the docs to the website.
      dCopyDir(cfg.nimLoc / "web" / "upload", cfg.websiteLoc / "docs")
      
      hubSendBuildSuccess()

    # --- Start of csources gen ---
    if cfg.csourceGen:
      # Rename the build directory so that the csources from the git repo aren't
      # overwritten
      hubSendJobUpdate(jCSrcGen)
      dMoveDir(cfg.nimLoc / "build", cfg.nimLoc / "build_old")
      dCreateDir(cfg.nimLoc / "build")

      run({"PATH": changeNimrodInPATH(cfg.nimLoc / "bin")}.newStringTable(),
          cfg.nimLoc, "koch", "csource")

      # Zip up the csources.
      # -- Move the build directory to the zip location
      let csourcesPath = commitPath & "_csources"
      var csourcesZipFile = (commitPath & "_csources").addFileExt("zip")
      dMoveDir(cfg.nimLoc / "build", cfg.zipLoc / csourcesPath / "build")
      # -- Move `build_old` to where it was previously.
      dMoveDir(cfg.nimLoc / "build_old", cfg.nimLoc / "build")
      # -- Copy build.sh and build.bat.
      dCopyFile(cfg.nimLoc / "build.sh", cfg.zipLoc / csourcesPath /
                 "build.sh")
      dCopyFile(cfg.nimLoc / "build.bat", cfg.zipLoc / csourcesPath /
                 "build.bat")
      # -- License
      dCopyFile(cfg.nimLoc / "copying.txt",
                cfg.zipLoc / csourcesPath / "copying.txt")
      dCopyFile(cfg.nimLoc / "gpl.html",
                cfg.zipLoc / csourcesPath / "gpl.html")
      writeFile(cfg.zipLoc / csourcesPath / "readme2.txt", buildReadme)
      # -- ZIP!
      if existsFile(cfg.zipLoc / csourcesZipFile):
        removeFile(cfg.zipLoc / csourcesZipFile)
      when defined(windows):
        echo("Not implemented")
        doAssert(false)
      run(cfg.zipLoc, findexe("zip"), "-r", csourcesZipFile, csourcesPath)
      hubSendBuildSuccess()

proc stopBuild(state: PState) =
  ## Terminates a build
  # TODO: Send a message to the website, make it record it to the database
  # as "terminated".
  if state.building:
    # Send the termination command first.
    threadCommandChan.send(ThreadTerminate)
    
    # Simply terminate the currently running process, should hopefully work.
    if state.buildJob.p != nil:
      echo("Terminating build")
      state.buildJob.p.terminate()

    # Block until thread exits.
    joinThreads(state.buildJob.thread)

proc beginBuild(state: PState) =
  ## This procedure starts the process of building nimrod. All it does
  ## is create a ``progress`` object, call ``buildProgressing()``,
  ## execute the ``git checkout .`` command and open a commit specific log file.
  
  # First make sure to stop any currently running process.
  state.stopBuild()
  
  # Create the BuildInfo object.
  var BuildData: TBuildData
  assert state.buildJob.payload != nil
  buildData.payload = state.buildJob.payload
  buildData.cfg = state.cfg

  # Create the thread.
  state.building = true
  createThread(state.buildJob.thread, bootstrapTmpl, BuildData)

proc pollBuild(state: PState) =
  ## This is called from the main loop; it checks whether the bootstrap
  ## thread has sent any messages through the channel and it then processes
  ## the messages.
  let msgCount = hubChan.peek()
  if msgCount > 0:
    for i in 0..msgCount-1:
      var msg = hubChan.recv()
      case msg.kind
      of ProcessStart:
        #p: PProcess
        state.buildJob.p = msg.p
      of ProcessExit:
        state.buildJob.p = nil
      of HubMsg:
        echo("[pollBuild] hubMsg: ", msg.msg)
        state.sock.send(msg.msg)
      of BuildEnd:
        state.building = false

# Communication
proc parseReply(line: string, expect: string): Bool =
  var jsonDoc = parseJson(line)
  return jsonDoc["reply"].str == expect

proc hubConnect(state: PState, reconnect: bool)
proc handleConnect(s: PAsyncSocket, state: PState) =
  try:
    # Send greeting
    var obj = newJObject()
    obj["name"] = newJString("builder")
    obj["platform"] = newJString(state.cfg.platform)
    if state.cfg.hubPass != "": obj["pass"] = newJString(state.cfg.hubPass)
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

      if state.cfg.requestNewest and not state.reconnecting:
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

proc handleHubMessage(s: PAsyncSocket, state: PState)
proc hubConnect(state: PState, reconnect: bool) =
  state.sock = AsyncSocket()
  state.sock.handleConnect = proc (s: PAsyncSocket) = handleConnect(s, state)
  state.sock.handleRead = proc (s: PAsyncSocket) = handleHubMessage(s, state)
  state.reconnecting = reconnect
  state.sock.connect(state.cfg.hubAddr, TPort(state.cfg.hubPort))
  state.dispatcher.register(state.sock)

proc open(configPath: string): PState =
  var cres: PState
  cres = defaultState()
  # Get config
  parseConfig(cres, configPath)
  if not existsDir(cres.cfg.nimLoc):
    quit(cres.cfg.nimLoc & " does not exist!", quitFailure)
  
  # Init dispatcher
  cres.dispatcher = newDispatcher()
  
  # Connect to the hub
  cres.hubConnect(false)

  # Open log file
  cres.logFile = open(cres.cfg.logLoc, fmAppend)
  
  # Init job
  cres.buildJob = initJob()

  result = cres

proc initJob(payload: PJsonNode): TJob =
  result.payload = payload

proc parseMessage(state: PState, line: string) =
  echo("Got message from hub: ", line)
  state.lastMsgTime = epochTime()
  var json = parseJson(line)
  if json.existsKey("payload"):
    if json["rebuild"].bval:
      # This commit has already been built. We don't get a full payload as
      # it is not stored.
      # Because the build process depends on "after" that is all that is
      # needed.
      assert(json["payload"].existsKey("after"))
      state.buildJob = initJob(json["payload"])
      echo("Re-bootstrapping!")
      state.beginBuild()
    else:
      # This should be a message from the "github" module
      # The payload object should have a `after` string.
      assert(json["payload"].existsKey("after"))
      state.buildJob = initJob(json["payload"])
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

proc handleHubMessage(s: PAsyncSocket, state: PState) =
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
  const timeoutSeconds = 110.0 # If no message received in that long, ping the server.

  if state.cfg.hubAddr != "127.0.0.1":
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

proc createFolders(state: PState) =
  if not existsDir(state.cfg.websiteLoc / "commits" / state.cfg.platform):
    dCreateDir(state.cfg.websiteLoc / "commits" / state.cfg.platform)

when isMainModule:
  echo("Started builder: built at ", CompileDate, " ", CompileTime)
  # TODO: Check for dependencies: unzip, zip, etc...
  var state = builder.open(parseArgs())
  createFolders(state)
  while True:
    discard state.dispatcher.poll()
    
    state.pollBuild()
  
    state.checkTimeout()
  

