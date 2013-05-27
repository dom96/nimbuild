import htmlgen, times, irc, streams, strutils, os, json, parseutils
from xmltree import escape

type
  TLogger = object # Items get erased when new day starts.
    startTime: TTimeInfo
    items: seq[tuple[time: TTime, msg: TIRCEvent]]
    logFilepath: string
    logFile: TFile
  PLogger* = ref TLogger

const
  webFP = {fpUserRead, fpUserWrite, fpUserExec,
           fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec}

proc doSkipError(s: string, toSkip: string, i: int): int =
  result = skip(s, toSkip, i)
  if result != toSkip.len:
    raise newException(EInvalidValue, "Expected '$1' got '$2'" %
                       [strutils.escape(toSkip), s[i .. i+toSkip.len-1]])

proc parseQuoted(logs: string, i: var int): string =
  ## Parses a quoted string.
  ## Resulting string contains ``"`` at start and end.
  result = ""
  if logs[i] != '\"':
    raise newException(EInvalidValue, "String does not begin with \"")
  result.add('\"')
  i.inc
  while true:
    case logs[i]
    of '\\':
      if i+1 > logs.len-1:
        raise newException(EInvalidValue, "Expected something after \\")
      result.add(logs[i] & logs[i+1])
      inc i
    of '"':
      result.add(logs[i])
      inc i
      break
    of '\0':
      raise newException(EInvalidValue,
              "Expected \" at the end of string, but reached end of string")
    else:
      result.add(logs[i])
    inc i
    
proc parseSeq(logs: string, i: var int): seq[string] =
  result = @[]
  i.inc doSkipError(logs, "[", i) # skip [
  var temp = ""
  while true:
    temp = parseQuoted(logs, i)
    result.add(unescape(temp))
    case logs[i]
    of ',':
      i.inc 1
    of ']':
      i.inc 1
      break
    else:
      raise newException(EInvalidValue, "Expected ',' or ']' got " & logs[i])

proc parseLogLine(logs: string, i: var int): tuple[time: TTime, msg: TIRCEvent] =
  var ircevent: TIRCEvent
  ircevent.typ = EvMsg
  # timestamp
  var timestamp: float
  i.inc parseFloat(logs, timestamp, i)

  # skip ,
  i.inc doSkipError(logs, ",", i)
  # cmd
  var cmd = ""
  i.inc parseUntil(logs, cmd, ',', i)
  ircevent.cmd = parseEnum[TIRCMType](cmd)
  i.inc doSkipError(logs, ",", i) # skip ,
   
  i.inc parseUntil(logs, ircevent.nick, ',', i) 
  i.inc doSkipError(logs, ",", i) # skip ,
  
  i.inc parseUntil(logs, ircevent.user, ',', i) 
  i.inc doSkipError(logs, ",", i) # skip ,
  
  i.inc parseUntil(logs, ircevent.host, ',', i) 
  i.inc doSkipError(logs, ",", i) # skip ,
  
  i.inc parseUntil(logs, ircevent.servername, ',', i) 
  i.inc doSkipError(logs, ",", i) # skip ,
  
  i.inc parseUntil(logs, ircevent.numeric, ',', i) 
  i.inc doSkipError(logs, ",", i) # skip ,

  ircevent.params = parseSeq(logs, i)
  i.inc doSkipError(logs, ",", i) # skip ,
  
  i.inc parseUntil(logs, ircevent.origin, ',', i) 
  i.inc doSkipError(logs, ",", i) # skip ,

  var escapedRaw = parseQuoted(logs, i)
  ircevent.raw = unescape(escapedRaw)
  i.inc doSkipError(logs, "\n", i) # skip \n
  
  return (fromSeconds(timestamp), ircevent)

proc load(f: string, logger: var PLogger) =
  var logs = readFile(f)
  var i = 0
  # Line 1: Start time
  var startTime: float
  i.inc parseFloat(logs, startTime, i)
  logger.startTime = fromSeconds(startTime).getGMTime()
  # Skip \n
  i.inc(doSkipError(logs, "\n", i))
  
  while logs[i] != '\0':
    logger.items.add(parseLogLine(logs, i))
  
  doAssert open(logger.logFile, f, fmAppend)

proc loadLogger*(f: string, result: var PLogger) =
  load(f, result)

proc writeFlush(file: TFile, s: string) =
  file.write(s)
  file.flushFile()

proc newLogger*(logFilepath: string): PLogger =
  new(result)
  result.startTime = getTime().getGMTime()
  result.items = @[]
  let log = logFilepath / result.startTime.format("dd'-'MM'-'yyyy'.logs'")
  if existsFile(log):
    loadLogger(log, result)
  else:
    result.logFilepath = logFilepath
    open(result.logFile, log, fmAppend)
    # Write start time
    result.logFile.writeFlush($epochTime() & "\n")

proc renderItems(logger: PLogger): string =
  result = ""
  for i in logger.items:
    var c = ""
    case i.msg.cmd
    of MJoin:
      c = "join"
    of MPart:
      c = "part"
    of MNick:
      c = "nick"
    of MQuit:
      c = "quit"
    else:
      nil
    var message = i.msg.params[i.msg.params.len-1]
    if message.startswith("\x01ACTION "):
      c = "action"
      message = message[8 .. -2]
    
    if c == "":
      result.add(tr(td(i.time.getGMTime().format("HH':'mm':'ss")),
                    td(class="nick", xmltree.escape(i.msg.nick)),
                    td(class="msg", xmltree.escape(message))))
    else:
      case c
      of "join":
        message = i.msg.nick & " joined " & i.msg.origin
      of "part":
        message = i.msg.nick & " left " & i.msg.origin & " (" & message & ")"
      of "nick":
        message = i.msg.nick & " is now known as " & message
      of "quit":
        message = i.msg.nick & " quit (" & message & ")"
      of "action":
        message = i.msg.nick & " " & message
      else: assert(false)
      result.add(tr(class=c,
                    td(i.time.getGMTime().format("HH':'mm':'ss")),
                    td(class="nick", "*"),
                    td(class="msg", xmltree.escape(message))))

proc renderHtml*(logger: PLogger, index = false): string =
  let previousDay = logger.startTime - (initInterval(days=1))
  let nextDay     = logger.startTime + (initInterval(days=1))
  let nextUrl     = if index: "" else: nextDay.format("dd'-'MM'-'yyyy'.html'")
  result = 
    html(
      head(title("#nimrod logs for " & logger.startTime.format("dd'-'MM'-'yyyy")),
           meta(content="text/html; charset=UTF-8", `http-equiv` = "Content-Type"),
           link(rel="stylesheet", href="/css/boilerplate.css"),
           link(rel="stylesheet", href="/css/log.css")
      ),
      body(
        htmlgen.`div`(id="controls",
            a(href=previousDay.format("dd'-'MM'-'yyyy'.html'"), "<<"),
            span(logger.startTime.format("dd'-'MM'-'yyyy")),
            (if nextUrl == "": span(">>") else: a(href=nextUrl, ">>"))
        ),
        hr(),
        table(
          renderItems(logger)
        )
      )
    )

proc `$`(s: seq[string]): string =
  var escaped = map(s) do (x: string) -> string:
    strutils.escape(x)
  result = "[" & join(escaped, ",") & "]"

proc writeLog(logger: PLogger, msg: TIRCEvent) =
  var text = ""
  text.add($epochTime() & ",")
  text.add($msg.cmd & ",")
  text.add((if msg.nick == nil: "" else: msg.nick) & ",")
  text.add((if msg.user == nil: "" else: msg.user) & ",")
  text.add((if msg.host == nil: "" else: msg.host) & ",")
  text.add((if msg.servername == nil: "" else: msg.servername) & ",")
  text.add((if msg.numeric == nil: "" else: msg.numeric) & ",")
  text.add($msg.params & ",")
  text.add((if msg.origin == nil: "" else: msg.origin) & ",")
  text.add(if msg.raw == nil: "\"\"" else: strutils.escape(msg.raw))
  logger.logFile.writeFlush(text & "\n")

proc log*(logger: PLogger, msg: TIRCEvent) =
  if msg.origin != "#nimrod" and msg.cmd notin {MQuit, MNick}: return
  if getTime().getGMTime().yearday != logger.startTime.yearday:
    # It's time to cycle to next day.
    # Reset logger.
    logger.logFile.close()
    logger.items = @[]
    logger.startTime = getTime().getGMTime()
    let log = logger.logFilepath / logger.startTime.format("dd'-'MM'-'yyyy'.logs'")
    doAssert open(logger.logFile, log, fmAppend)
    # Write start time
    logger.logFile.writeFlush($epochTime() & "\n")
    
  case msg.cmd
  of MPrivMsg, MJoin, MPart, MNick, MQuit: # TODO: MTopic? MKick?
    logger.items.add((getTime(), msg))
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
  logger.log("dom96", "Hello\r, testing, \"\"", "#nimrod")
  loadLogger("testing/logstest/26-05-2013.logs", logger)
  echo repr(logger)