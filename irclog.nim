import htmlgen, times, irc, marshal, streams, strutils, os, json
from xmltree import escape

type
  TLogger = object # Items get erased when new day starts.
    startTime: TTimeInfo
    items: seq[tuple[time: TTime, msg: TIRCEvent]]
    logFilepath: string
  PLogger* = ref TLogger

const
  webFP = {fpUserRead, fpUserWrite, fpUserExec,
           fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec}

proc loadLogger(f: string): PLogger =
  load(newFilestream(f, fmRead), result)

proc newLogger*(logFilepath: string): PLogger =
  new(result)
  result.startTime = getTime().getGMTime()
  result.items = @[]
  result.logFilepath = logFilepath
  let log = logFilepath / result.startTime.format("dd'-'MM'-'yyyy'.json'")
  if existsFile(log):
    result = loadLogger(log)

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

discard """proc renderJSONItems(logger: PLogger): PJsonNode =
  result = newJArray()
  for i in logger.items:
    result.add(%{ "cmd": %($i.cmd),
                  "msg": %i.msg.params[i.msg.params.len-1] })

proc renderJSON(logger: PLogger): string =
  let json = %{ "startTime": %logger.startTime.TimeInfoToTime.int,
                "savedAt" :  %epochTime(),
                "logs": renderJSONItems(logger)}
  result = json.pretty()"""

proc save(logger: PLogger, filename: string, index = false) =
  writeFile(filename, renderHtml(logger, index))
  setFilePermissions(filename, webFP)
  #if not index:
  #  writeFile(filename.changeFileExt("json"), $$logger)

proc log*(logger: PLogger, msg: TIRCEvent) =
  if msg.origin != "#nimrod" and msg.cmd notin {MQuit, MNick}: return
  if getTime().getGMTime().yearday != logger.startTime.yearday:
    # It's time to cycle to next day.
    # Reset logger.
    logger.startTime = getTime().getGMTime()
    logger.items = @[]
    
  case msg.cmd
  of MPrivMsg, MJoin, MPart, MNick, MQuit: # TODO: MTopic? MKick?
    logger.items.add((getTime(), msg))
    logger.save(logger.logFilepath / "index.html", true)
    logger.save(logger.logFilepath / logger.startTime.format("dd'-'MM'-'yyyy'.html'"))
  else: nil

proc log*(logger: PLogger, nick, msg, chan: string) =
  var m: TIRCEvent
  m.typ = EvMsg
  m.cmd = MPrivMsg
  m.params = @[chan, msg]
  m.origin = chan
  m.nick = nick
  logger.log(m)
