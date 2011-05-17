# This will build nimrod using the specified settings.
import osproc, json, sockets, os, streams, parsecfg, parseopt, strutils
import types

const
  builderVer = "0.1"

type
  TCurrentProc = enum
    pullProc, 
    clean, unzipCSources, buildSh, ## Compiling from C Sources
    compileKoch, bootNimDebug, bootNim, ## Bootstrapping
    zipNim, bz2Nim, # archive
    compileTester, runTests # Testing
    
  TProgress = object
    currentProc: TCurrentProc
    p: PProcess
    payload: PJsonNode

  TState = object
    sock: TSocket
    status: TStatus ## Outcome of the build
    progress: TProgress ## Current progress
    skipCSource: bool ## Skip the process of building csources
    nimLoc: string ## Location of the nimrod repo
    websiteLoc: string ## Location of the website.
    websiteURL: string ## URL of the website
    logLoc: string ## Location of the logs for this module.
    logFile: TFile
    zipLoc: string ## Location of where to copy the files for zipping.
    platform: string

# Configuration
proc parseConfig(state: var TState, path: string) =
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
        of "websiteurl":
          state.websiteURL = n.value
          inc(count)
        of "logfilepath":
          state.logLoc = n.value
          inc(count)
        of "archivepath":
          state.zipLoc = n.value
          inc(count)
      of cfgError:
        raise newException(EInvalidValue, "Configuration parse error: " & n.msg)
    if count != 6: 
      quit("Not all settings have been specified in the .ini file", quitFailure)
    close(p)
  else:
    quit("Cannot open configuration file: " & path, quitFailure)

# Build of Nimrod/tests/docs gen
proc buildFailed(state: var TState, desc: string) =
  state.status.status = sBuildFailure
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sBuildFailure))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)
  
  state.sock.send($obj & "\c\L")
  echo(desc)

proc buildProgressing(state: var TState, desc: string) =
  state.status.status = sBuildInProgress
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sBuildInProgress))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)
  
  state.sock.send($obj & "\c\L")
  echo(desc)

proc buildSucceeded(state: var TState) =
  state.status.status = sBuildSuccess
  var obj = newJObject()
  obj["status"] = newJInt(int(sBuildSuccess))
  obj["hash"] = newJString(state.progress.payload["after"].str)

  state.sock.send($obj & "\c\L")
  echo("Build successfully completed")

proc testingFailed(state: var TState, desc: string) =
  state.status.status = sTestFailure
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sTestFailure))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)

  state.sock.send($obj & "\c\L")
  echo(desc)

proc testProgressing(state: var TState, desc: string) =
  state.status.status = sTestInProgress
  state.status.desc = desc
  var obj = newJObject()
  obj["status"] = newJInt(int(sTestInProgress))
  obj["desc"] = newJString(desc)
  obj["hash"] = newJString(state.progress.payload["after"].str)
 
  state.sock.send($obj & "\c\L")
  echo(desc)

proc testSucceeded(state: var TState) =
  state.status.status = sTestSuccess
  var obj = newJObject()
  obj["status"] = newJInt(int(sTestSuccess))
  obj["hash"] = newJString(state.progress.payload["after"].str)

  state.sock.send($obj & "\c\L")
  echo("Tests completed")

proc startMyProcess(cmd, workDir: string, args: openarray[string]): PProcess =
  result = startProcess(cmd, workDir, args,
                        nil, {poStdErrToStdOut})

proc dCopyFile(src, dest: string) =
  echo("[INFO] Copying ", src, " to ", dest)
  copyFile(src, dest)

proc dCopyDir(src, dest: string) =
  echo("[INFO] Copying directory ", src, " to ", dest)
  copyDir(src, dest)

proc dCreateDir(s: string) =
  echo("[INFO] Creating directory ", s)
  createDir(s)

proc copyForArchive(nimLoc, dest: string) =
  dCreateDir(dest / "bin")
  var nimBin = "bin" / addFileExt("nimrod", ExeExt)
  dCopyFile(nimLoc / nimBin, dest / nimBin)
  dCopyFile(nimLoc / "readme.txt", dest / "readme.txt")
  
  dCopyDir(nimLoc / "config", dest / "config")
  dCopyDir(nimLoc / "lib", dest / "lib")

proc beginBuild(state: var TState) =
  ## This procedure starts the process of building nimrod. All it does
  ## is create a ``progress`` object, call ``buildProgressing()`` and 
  ## execute the ``git pull`` command.

  state.progress.currentProc = pullProc
  state.progress.p = startMyProcess(findExe("git"), state.nimLoc, "pull")
  state.buildProgressing("Executing the git pull command.")

proc nextStage(state: var TState) =
  case state.progress.currentProc
  of pullProc:
    if not state.skipCSource:
      state.progress.currentProc = clean
      state.progress.p = startMyProcess("koch", 
          state.nimLoc, "clean")
      state.buildProgressing("Executing koch clean")
    else:
      # Same code as in ``of buildSh:``
      state.progress.currentProc = compileKoch
      state.progress.p = startMyProcess("bin/nimrod", 
          state.nimLoc, "c", "koch.nim")
      state.buildProgressing("Compiling koch.nim")
  of clean:
    state.progress.currentProc = unzipCSources
    state.progress.p = startMyProcess(findExe("unzip"), 
        state.nimLoc / "build", "csources.zip")
    state.buildProgressing("Executing unzip")
  of unzipCSources:
    state.progress.currentProc = buildSh
    state.progress.p = startMyProcess(findExe("sh"),
        state.nimLoc, "build.sh")
    state.buildProgressing("Compiling C sources")
  of buildSh:
    state.progress.currentProc = compileKoch
    state.progress.p = startMyProcess("bin/nimrod", 
        state.nimLoc, "c", "koch.nim")
    state.buildProgressing("Compiling koch.nim")
  of compileKoch:
    state.progress.currentProc = bootNimDebug
    state.progress.p = startMyProcess("koch", 
        state.nimLoc, "boot")
    state.buildProgressing("Bootstrapping Nimrod")
  of bootNimDebug:
    state.progress.currentProc = bootNim
    state.progress.p = startMyProcess("koch", 
        state.nimLoc, "boot", "-d:release")
    state.buildProgressing("Bootstrapping Nimrod in release mode")
  of bootNim, zipNim:
    var commitHash = state.progress.payload["after"].str
    var folderName = makeArchivePath(state.platform, commitHash)
    var dir = state.zipLoc / folderName
    var zipFile = addFileExt(folderName, "zip")
    var bz2File = addFileExt(folderName, "tar.bz2")
    
    dCreateDir(dir)
    # TODO: This will block :(
    copyForArchive(state.nimLoc, dir)
    
    if state.progress.currentProc == bootNim:
      # Remove the .zip in case they already exist...
      if existsFile(state.zipLoc / zipFile): removeFile(state.zipLoc / zipFile)
      state.progress.currentProc = zipNim
      state.progress.p = startMyProcess(findexe("zip"), 
          state.zipLoc, "-r", zipFile, folderName)
      state.buildProgressing("Creating archive - zip")
    
    elif state.progress.currentProc == zipNim:
      if existsFile(state.zipLoc / bz2File): removeFile(state.zipLoc / bz2File)
      state.progress.currentProc = bz2Nim
      state.progress.p = startMyProcess(findexe("tar"), 
          state.zipLoc, "-jcvf", bz2File, folderName)
      state.buildProgressing("Creating archive - tar.bz2")
  
  of bz2Nim:
    # Copy the .zip and .tar.bz2 files
    var commitHash = state.progress.payload["after"].str
    var fileName = makeArchivePath(state.platform, commitHash)
    var zip = addFileExt(fileName, "zip")
    var bz2 = addFileExt(fileName, ".tar.bz2")
    dCreateDir(state.websiteLoc / "downloads" / state.platform)
    dCopyFile(state.zipLoc / zip, state.websiteLoc / "downloads" / zip)
    dCopyFile(state.zipLoc / bz2, state.websiteLoc / "downloads" / bz2)
    
    buildSucceeded(state)
  
    # --- Start of tests ---
    
    # Start test suite!
    state.progress.currentProc = compileTester
    state.progress.p = startMyProcess("bin/nimrod", 
          state.nimLoc, "c", "tests/tester.nim")
    testProgressing(state, "Compiling tests/tester.nim")
    
  of compileTester:
    state.progress.currentProc = runTests
    state.progress.p = startMyProcess("tests/tester", state.nimLoc)
    testProgressing(state, "Testing nimrod build...")
    
  of runTests:
    # Copy the testresults.html file.
    var commitHash = state.progress.payload["after"].str.copy(0, 11)
    # TODO: Make a function which creates this so that website.nim can reuse it from types.nim
    var folderName = state.platform / "nimrod_" & commitHash
    dCreateDir(state.websiteLoc / "downloads" / folderName)
    setFilePermissions(state.websiteLoc / "downloads" / folderName,
                       {fpGroupRead, fpGroupExec, fpOthersRead,
                        fpOthersExec, fpUserWrite,
                        fpUserRead, fpUserExec})
                        
    dCopyFile(state.nimLoc / "testresults.html",
              state.websiteLoc / "downloads" / folderName / "testresults.html")
    testSucceeded(state)
    # TODO: Copy testresults.json too?

proc checkProgress(state: var TState) =
  ## This is called from the main loop - checks the progress of the current
  ## process being run as part of the build/test process.
  if isInProgress(state.status.status):
    var p: PProcess
    p = state.progress.p
    
    assert p != nil
    var readP = @[p]
    if select(readP) == 1 and readP.len == 0:
      var output = p.outputStream.readLine()
      echo("Got output from ", state.progress.currentProc, ". Len = ", 
           output.len)
      # TODO: If you get more problems with process exit not being detected by
      # peekExitCode then implement a counter of how many messages of len 0
      # have been received FOR EACH PROCESS. Using waitForExit doesn't seem to
      # work... GAH. (Gives 3 0_o)
      state.logFile.write(output & "\n")
      state.logFile.flushFile()
    
    var exitCode = p.peekExitCode
    echo("Got exit code: ", exitCode, " ", exitCode != -1)
    if exitCode != -1:
      if exitCode == QuitSuccess:
        echo(state.progress.currentProc,
             " exited successfully. Continuing to next stage.")
        state.nextStage()
      else:
        var output = p.outputStream.readLine()
        echo(output)
        if state.progress.currentProc <= bz2nim:
          echo(state.progress.currentProc,
               " failed. Build failed! Exit code = ", exitCode)
          buildFailed(state, $state.progress.currentProc &
                      " failed with exit code 1")
        elif state.progress.currentProc <= runTests:
          echo(state.progress.currentProc,
               " failed. Running tests failed! Exit code = ", exitCode)
          testingFailed(state, $state.progress.currentProc &
                        " failed with exit code 1")

# Communication
proc parseReply(line: string, expect: string): Bool =
  var jsonDoc = parseJson(line)
  return jsonDoc["reply"].str == expect

proc open(configPath: string, port: TPort = TPort(5123)): TState =
  # Get config
  parseConfig(result, configPath)
  if not existsDir(result.nimLoc):
    quit(result.nimLoc & " does not exist!", quitFailure)
  
  result.sock = socket()
  result.sock.connect("127.0.0.1", port)
  
  # Send greeting
  var obj = newJObject()
  obj["name"] = newJString("builder")
  obj["platform"] = newJString(result.platform)
  result.sock.send($obj & "\c\L")
  # Wait for reply.
  var readSocks = @[result.sock]
  if select(readSocks, 1500) == 1 and readSocks.len == 0:
    var line = ""
    assert result.sock.recvLine(line)
    assert parseReply(line, "OK")
    echo("The hub accepted me!")
  else:
    raise newException(EInvalidValue, 
                       "Hub didn't accept me. Waited 1.5 seconds.")
  
  # Open log file
  result.logFile = open(result.logLoc, fmAppend)
  
  # Init status
  result.status = initStatus()

proc fileInModified(json: PJsonNode, file: string): bool =
  for commit in items(json["commits"].elems):
    for f in items(commit["modified"].elems):
      if f.str == file: return true

proc handleMessage(state: var TState, line: string) =
  echo("Got message from hub: ", line)
  var json = parseJson(line)
  if json.existsKey("payload"):
    # This should be a message from the "github" module
    # The payload object should have a `after` string.
    assert(json["payload"].existsKey("after"))
    state.skipCSource = not fileInModified(json["payload"], "csources.zip")
    state.progress.payload = json["payload"]
    echo("Bootstrapping!")
    state.beginBuild()

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
  var state = builder.open(parseArgs())
  var readSock: seq[TSocket] = @[]
  while True:
    readSock = @[state.sock]
    if select(readSock, 200) == 1 and readSock.len == 0:
      var line = ""
      if state.sock.recvLine(line):
        state.handleMessage(line)
      else:
        # TODO: Try reconnecting.
        OSError()
    
    state.checkProgress()
  
  
  

