import htmlgen, times, irc, streams, strutils, os, json, parseutils, marshal
from xmltree import escape

type
  TLogger = object # Items get erased when new day starts.
    startTime: TTimeInfo
    items: seq[tuple[time: TTime, msg: TIRCEvent]] ## Only used for HTML gen
    logFilepath: string
    logFile: TFile
  PLogger* = ref TLogger

const
  webFP = {fpUserRead, fpUserWrite, fpUserExec,
           fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec}

proc loadLogger*(f: string, forRender: bool): PLogger =
  new(result)
  result.items = @[]
  let logs = readFile(f)
  let lines = logs.splitLines()
  var i = 1
  # Line 1: Start time
  result.startTime = fromSeconds(to[float](lines[0])).getGMTime()
  
  if forRender:
    while i < lines.len:
      if lines[i] != "":
        result.items.add(to[tuple[time: TTime, msg: TIRCEvent]](lines[i]))
      inc i
  
  if not forRender:
    doAssert open(result.logFile, f, fmAppend)
  result.logFilepath = f.splitFile.dir

proc writeFlush(file: TFile, s: string) =
  file.write(s)
  file.flushFile()

proc newLogger*(logFilepath: string): PLogger =
  let startTime = getTime().getGMTime()
  let log = logFilepath / startTime.format("dd'-'MM'-'yyyy'.logs'")
  if existsFile(log):
    result = loadLogger(log, false)
  else:
    new(result)
    result.startTime = startTime
    result.items = @[]
    result.logFilepath = logFilepath
    open(result.logFile, log, fmAppend)
    # Write start time
    result.logFile.writeFlush($$epochTime() & "\n")

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
  logger.logFile.writeFlush($$(time: getTime(), msg: msg) & "\n")

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
  logger.log("dom96", "Hello\r, testing, \"\"", "#nimrod")
  #logger = loadLogger("testing/logstest/26-05-2013.logs")
  echo repr(logger)