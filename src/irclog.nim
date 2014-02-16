import htmlgen, times, irc, streams, strutils, os, json, parseutils, marshal
from xmltree import escape

type
  TLogger* = object of TObject # Items get erased when new day starts.
    startTime*: TTimeInfo
    logFilepath*: string
    logFile*: TFile
  PLogger* = ref TLogger

const
  webFP = {fpUserRead, fpUserWrite, fpUserExec,
           fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec}

proc loadLogger*(f: string): PLogger =
  new(result)
  let logs = readFile(f)
  let lines = logs.splitLines()
  # Line 1: Start time
  result.startTime = fromSeconds(to[float](lines[0])).getGMTime()
  
  doAssert open(result.logFile, f, fmAppend)
  result.logFilepath = f.splitFile.dir

proc writeFlush(file: TFile, s: string) =
  file.write(s)
  file.flushFile()

proc newLogger*(logFilepath: string): PLogger =
  let startTime = getTime().getGMTime()
  let log = logFilepath / startTime.format("dd'-'MM'-'yyyy'.logs'")
  if existsFile(log):
    result = loadLogger(log)
  else:
    new(result)
    result.startTime = startTime
    result.logFilepath = logFilepath
    doAssert open(result.logFile, log, fmAppend)
    # Write start time
    result.logFile.writeFlush($$epochTime() & "\n")

proc `$`(s: seq[string]): string =
  var escaped = system.map(s) do (x: string) -> string:
    strutils.escape(x)
  result = "[" & join(escaped, ",") & "]"

proc writeLog(logger: PLogger, msg: TIRCEvent) =
  logger.logFile.writeFlush($$(time: getTime(), msg: msg) & "\n")

proc log*(logger: PLogger, msg: TIRCEvent) =
  if msg.origin != "#nimrod" and msg.cmd notin {MQuit, MNick}: return
  if getTime().getGMTime().yearday != logger.startTime.yearday:
    # It's time to cycle to next day.
    # Reset logger.
    logger.logFile.close()
    logger.startTime = getTime().getGMTime()
    let log = logger.logFilepath / logger.startTime.format("dd'-'MM'-'yyyy'.logs'")
    doAssert open(logger.logFile, log, fmAppend)
    # Write start time
    logger.logFile.writeFlush($epochTime() & "\n")
    
  case msg.cmd
  of MPrivMsg, MJoin, MPart, MNick, MQuit: # TODO: MTopic? MKick?
    #logger.items.add((getTime(), msg))
    #logger.save(logger.logFilepath / logger.startTime.format("dd'-'MM'-'yyyy'.json'"))
    writeLog(logger, msg)
  else: nil

proc log*(logger: PLogger, nick, msg, chan: string) =
  var m: TIRCEvent
  m.typ = EvMsg
  m.cmd = MPrivMsg
  m.params = @[chan, msg]
  m.origin = chan
  m.nick = nick
  logger.log(m)

when isMainModule:
  var logger = newLogger("testing/logstest")
  logger.log("dom96", "Hello!", "#nimrod")
  logger.log("dom96", "Hello\r, testingí, \"\"", "#nimrod")
  #logger = loadLogger("testing/logstest/26-05-2013.logs")
  echo repr(logger)