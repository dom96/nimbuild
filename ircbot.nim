import irc, sockets, asyncio, json, os, strutils, db, times, redis, irclog


type
  PState = ref TState
  TState = object of TObject
    dispatcher: PDispatcher
    sock: PAsyncSocket
    ircClient: PAsyncIRC
    hubPort: TPort
    database: TDb
    dbConnected: bool
    logger: PLogger

  TSeenType = enum
    PSeenJoin, PSeenPart, PSeenMsg, PSeenNick, PSeenQuit
  
  TSeen = object
    nick: string
    channel: string
    timestamp: TTime
    case kind*: TSeenType
    of PSeenJoin: nil
    of PSeenPart, PSeenQuit, PSeenMsg:
      msg: string
    of PSeenNick:
      newNick: string

const 
  ircServer = "irc.freenode.net"
  joinChans = @["#nimrod"]
  botNickname = "NimBot"

proc setSeen(d: TDb, s: TSeen) =
  discard d.r.del("seen:" & s.nick)

  var hashToSet = @[("type", $s.kind.int), ("channel", s.channel),
                    ("timestamp", $s.timestamp.int)]
  case s.kind
  of PSeenJoin: nil
  of PSeenPart, PSeenMsg, PSeenQuit:
    hashToSet.add(("msg", s.msg))
  of PSeenNick:
    hashToSet.add(("newnick", s.newNick))
  
  d.r.hMSet("seen:" & s.nick, hashToSet)

proc getSeen(d: TDb, nick: string, s: var TSeen): bool =
  if d.r.exists("seen:" & nick):
    result = true
    s.nick = nick
    # Get the type first
    s.kind = d.r.hGet("seen:" & nick, "type").parseInt.TSeenType
    
    for key, value in d.r.hPairs("seen:" & nick):
      case normalize(key)
      of "type":
        #s.kind = value.parseInt.TSeenType
      of "channel":
        s.channel = value
      of "timestamp":
        s.timestamp = TTime(value.parseInt)
      of "msg":
        s.msg = value
      of "newnick":
        s.newNick = value

template createSeen(typ: TSeenType, n, c: string): stmt =
  var seenNick: TSeen
  seenNick.kind = typ
  seenNick.nick = n
  seenNick.channel = c
  seenNick.timestamp = getTime()

proc parseReply(line: string, expect: string): Bool =
  var jsonDoc = parseJson(line)
  return jsonDoc["reply"].str == expect

proc limitCommitMsg(m: string): string =
  ## Limits the message to 300 chars and adds ellipsis.
  var m1 = m
  if NewLines in m1:
    m1 = m1.splitLines()[0]
  
  if m1.len >= 300:
    m1 = m1[0..300]

  if m1.len >= 300 or NewLines in m: m1.add("... ")

  if NewLines in m: m1.add($m.splitLines().len & " more lines")

  return m1

proc handleWebMessage(state: PState, line: string) =
  echo("Got message from hub: " & line)
  var json = parseJson(line)
  if json.existsKey("payload"):
    for i in 0..min(4, json["payload"]["commits"].len-1):
      var commit = json["payload"]["commits"][i]
      # Create the message
      var message = ""
      message.add(json["payload"]["repository"]["owner"]["name"].str & "/" &
                  json["payload"]["repository"]["name"].str & " ")
      message.add(commit["id"].str[0..6] & " ")
      message.add(commit["author"]["name"].str & " ")
      message.add("[+" & $commit["added"].len & " ")
      message.add("±" & $commit["modified"].len & " ")
      message.add("-" & $commit["removed"].len & "]: ")
      message.add(limitCommitMsg(commit["message"].str))

      # Send message to #nimrod.
      state.ircClient[].privmsg(joinChans[0], message)
  elif json.existsKey("redisinfo"):
    assert json["redisinfo"].existsKey("port")
    let redisPort = json["redisinfo"]["port"].num
    state.database = db.open(port = TPort(redisPort))
    state.dbConnected = true

proc hubConnect(state: PState)
proc handleConnect(s: PAsyncSocket, userArg: PObject) =
  let state = PState(userArg)
  try:
    # Send greeting
    var obj = newJObject()
    obj["name"] = newJString("irc")
    obj["platform"] = newJString("?")
    state.sock.send($obj & "\c\L")

    # Wait for reply.
    var line = ""
    sleep(1500)
    if state.sock.recvLine(line):
      assert(line != "")
      doAssert parseReply(line, "OK")
      echo("The hub accepted me!")
    else:
      raise newException(EInvalidValue,
                         "Hub didn't accept me. Waited 1.5 seconds.")
    
    # ask for the redis info
    var riobj = newJObject()
    riobj["do"] = newJString("redisinfo")
    state.sock.send($riobj & "\c\L")
    
  except EOS, EInvalidValue, EAssertionFailed:
    echo(getCurrentExceptionMsg())
    s.close()
    echo("Waiting 5 seconds...")
    sleep(5000)
    state.hubConnect()

proc handleRead(s: PAsyncSocket, userArg: PObject) =
  let state = PState(userArg)
  var line = ""
  if state.sock.recvLine(line):
    if line != "":
      # Handle the message
      state.handleWebMessage(line)
    else:
      echo("Disconnected from hub: ", OSErrorMsg())
      s.close()
      echo("Reconnecting...")
      state.hubConnect()
  else:
    echo(OSErrorMsg())

proc hubConnect(state: PState) =
  state.sock = AsyncSocket()
  state.sock.connect("127.0.0.1", state.hubPort)
  state.sock.userArg = state
  state.sock.handleConnect = handleConnect
  state.sock.handleRead = handleRead

  state.dispatcher.register(state.sock)

proc handleIrc(irc: var TAsyncIRC, event: TIRCEvent, userArg: PObject) =
  let state = PState(userArg)
  case event.typ
  of EvDisconnected:
    while not state.ircClient[].isConnected:
      try:
        state.ircClient.connect()
      except:
        echo("Error reconnecting: ", getCurrentExceptionMsg())
      
      echo("Waiting 5 seconds...")
      sleep(5000)
    echo("Reconnected successfully!")
  of EvMsg:
    echo("< ", event.raw)
    case event.cmd
    of MPrivMsg:
      let msg = event.params[event.params.len-1]
      let words = msg.split(' ')
      template pm(msg: string): stmt = 
        state.ircClient[].privmsg(event.origin, msg)
      case words[0]
      of "!ping": pm("pong")
      of "!lag":
        if state.ircClient[].getLag != -1.0:
          var lag = state.ircClient[].getLag
          lag = lag * 1000.0
          pm($int(lag) & "ms between me and the server.")
        else:
          pm("Unknown.")
      of "!seen":
        if words.len > 1:
          let nick = words[1]
          if nick == botNickname:
            pm("Yes, I see myself.")
          echo(nick)
          var seenInfo: TSeen
          if state.database.getSeen(nick, seenInfo):
            var mSend = ""
            case seenInfo.kind
            of PSeenMsg:
              pm("$1 was last seen on $2 in $3 saying: $4" % 
                    [seenInfo.nick, $seenInfo.timestamp,
                     seenInfo.channel, seenInfo.msg])
            of PSeenJoin:
              pm("$1 was last seen on $2 joining $3" % 
                        [seenInfo.nick, $seenInfo.timestamp, seenInfo.channel])
            of PSeenPart:
              pm("$1 was last seen on $2 leaving $3 with message: $4" % 
                        [seenInfo.nick, $seenInfo.timestamp, seenInfo.channel,
                         seenInfo.msg])
            of PSeenQuit:
              pm("$1 was last seen on $2 quitting with message: $3" % 
                        [seenInfo.nick, $seenInfo.timestamp, seenInfo.msg])
            of PSeenNick:
              pm("$1 was last seen on $2 changing nick to $3" % 
                        [seenInfo.nick, $seenInfo.timestamp, seenInfo.newNick])
            
          else:
            pm("I have not seen " & nick)
        else:
          pm("Syntax: !seen <nick>")
      
      if words[0].startswith("!kirbyrape"):
        pm("(>^(>O_O)>")
      
      # TODO: ... commands

      # -- Seen
      #      Log this as activity.
      createSeen(PSeenMsg, event.nick, event.origin)
      seenNick.msg = msg
      state.database.setSeen(seenNick)
    of MJoin:
      createSeen(PSeenJoin, event.nick, event.origin)
      state.database.setSeen(seenNick)
    of MPart:
      createSeen(PSeenPart, event.nick, event.origin)
      let msg = event.params[event.params.high]
      seenNick.msg = msg
      state.database.setSeen(seenNick)
    of MQuit:
      createSeen(PSeenQuit, event.nick, event.origin)
      let msg = event.params[event.params.high]
      seenNick.msg = msg
      state.database.setSeen(seenNick)
    of MNick:
      createSeen(PSeenNick, event.nick, "#nimrod")
      seenNick.newNick = event.params[0]
      state.database.setSeen(seenNick)
    else:
      nil # TODO: ?

    # Logs:
    state.logger.log(event)

proc open(port: TPort = TPort(5123)): PState =
  new(result)
  result.dispatcher = newDispatcher()
  
  result.hubPort = port
  result.hubConnect()

  # Connect to the irc server.
  result.ircClient = AsyncIrc(ircServer, nick = botNickname, user = botNickname,
                 joinChans = joinChans, ircEvent = handleIrc, userArg = result)
  result.ircClient.connect()
  result.dispatcher.register(result.ircClient)

  result.dbConnected = false

  result.logger = newLogger()

var state = ircbot.open() # Connect to the website and the IRC server.

while state.dispatcher.poll():
  if state.dbConnected:
    state.database.keepAlive()

