import irc, sockets, asyncio, json, os, strutils, db, times, redis, irclog, marshal, streams


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
    settings: TSettings
  
  TSettings = object
    trustedUsers: seq[tuple[nick: string, host: string]]
    announceRepos: seq[string]
    announceChans: seq[string]
    announceNicks: seq[string]

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

proc initSettings(settings: var TSettings) =
  settings.trustedUsers = @[(nick: "dom96", host: "unaffiliated/dom96")]
  settings.announceRepos = @[]
  settings.announceChans = @["#nimbuild"]
  settings.announceNicks = @[]

proc saveSettings(state: PState) =
  store(newFileStream("nimbot.json", fmWrite), state.settings)

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

template createSeen(typ: TSeenType, n, c: string): stmt {.immediate, dirty.} =
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

template pm(chan, msg: string): stmt = 
  state.ircClient[].privmsg(chan, msg)
  state.logger.log("NimBot", msg)

proc announce(state: PState, msg: string, important: bool) =
  var msg = ""
  if important:
    msg.add(join(state.settings.announceNicks, ","))
    msg.add(": ")
  msg.add(msg)
  for i in state.settings.announceChans:
    pm(i, msg)

proc isRepoAnnounced(state: PState, url: string): bool =
  result = false
  for repo in state.settings.announceRepos:
    if url.ToLower().endswith(repo.ToLower()):
      return true

proc handleWebMessage(state: PState, line: string) =
  echo("Got message from hub: " & line)
  var json = parseJson(line)
  if json.existsKey("payload"):
    if isRepoAnnounced(state, json["payload"]["repository"]["url"].str):
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
        pm(joinChans[0], message)
  elif json.existsKey("redisinfo"):
    assert json["redisinfo"].existsKey("port")
    let redisPort = json["redisinfo"]["port"].num
    state.database = db.open(port = TPort(redisPort))
    state.dbConnected = true
  elif json.existsKey("announce"):
    announce(state, json["announce"].str, json["important"].bval)
    
proc hubConnect(state: PState)
proc handleConnect(s: PAsyncSocket, state: PState) =
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

proc handleRead(s: PAsyncSocket, state: PState) =
  var line = ""
  if state.sock.recvLine(line):
    if line != "":
      # Handle the message
      state.handleWebMessage(line)
    else:
      echo("Disconnected from hub: ", OSErrorMsg())
      announce(state, "Got disconnected from hub! " & OSErrorMsg(), true)
      state.sock.close()
      echo("Reconnecting...")
      state.hubConnect()
  else:
    echo(OSErrorMsg())

proc hubConnect(state: PState) =
  state.sock = AsyncSocket()
  state.sock.connect("127.0.0.1", state.hubPort)
  state.sock.handleConnect = proc (s: PAsyncSocket) = handleConnect(s, state)
  state.sock.handleRead = proc (s: PAsyncSocket) = handleRead(s, state)

  state.dispatcher.register(state.sock)

proc isUserTrusted(state: PState, nick, host: string): bool =
  for i in state.settings.trustedUsers:
    if i.nick == nick and i.host == host:
      return true
  return false

proc addDup[T](s: var seq[T], v: T) =
  ## Adds only if it doesn't already exist in seq.
  if v notin s:
    s.add(v)

proc delTrust(s: var seq[tuple[nick: string, host: string]], nick, host: string): bool =
  for i in 0..s.len-1:
    if s[i].nick == nick and s[i].host == host:
      s.del(i)
      return true
  return false

proc del[T](s: var seq[T], v: T): bool =
  for i in 0..s.len-1:
    if s[i] == v:
      s.del(i)
      return true
  return false

proc `$`(s: seq[tuple[nick: string, host: string]]): string =
  result = ""
  for i in s:
    result.add(i.nick & "@" & i.host & ", ")
  result = result[0 .. -3]

proc handleIrc(irc: var TAsyncIRC, event: TIRCEvent, state: PState) =
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
    # Logs:
    state.logger.log(event)
    template pmOrig(msg: string) =
      pm(event.origin, msg)
    case event.cmd
    of MPrivMsg:
      let msg = event.params[event.params.len-1]
      let words = msg.split(' ')
      case words[0]
      of "!ping": pmOrig("pong")
      of "!lag":
        if state.ircClient[].getLag != -1.0:
          var lag = state.ircClient[].getLag
          lag = lag * 1000.0
          pmOrig($int(lag) & "ms between me and the server.")
        else:
          pmOrig("Unknown.")
      of "!seen":
        if words.len > 1:
          let nick = words[1]
          if nick == botNickname:
            pmOrig("Yes, I see myself.")
          var seenInfo: TSeen
          if state.database.getSeen(nick, seenInfo):
            case seenInfo.kind
            of PSeenMsg:
              pmOrig("$1 was last seen on $2 in $3 saying: $4" % 
                    [seenInfo.nick, $seenInfo.timestamp,
                     seenInfo.channel, seenInfo.msg])
            of PSeenJoin:
              pmOrig("$1 was last seen on $2 joining $3" % 
                        [seenInfo.nick, $seenInfo.timestamp, seenInfo.channel])
            of PSeenPart:
              pmOrig("$1 was last seen on $2 leaving $3 with message: $4" % 
                        [seenInfo.nick, $seenInfo.timestamp, seenInfo.channel,
                         seenInfo.msg])
            of PSeenQuit:
              pmOrig("$1 was last seen on $2 quitting with message: $3" % 
                        [seenInfo.nick, $seenInfo.timestamp, seenInfo.msg])
            of PSeenNick:
              pmOrig("$1 was last seen on $2 changing nick to $3" % 
                        [seenInfo.nick, $seenInfo.timestamp, seenInfo.newNick])
            
          else:
            pmOrig("I have not seen " & nick)
        else:
          pmOrig("Syntax: !seen <nick>")
      of "!addtrust":
        if words.len > 2:
          if isUserTrusted(state, event.nick, event.host):
            state.settings.trustedUsers.addDup((words[1], words[2]))
            saveSettings(state)
            pmOrig("Done.")
          else:
            pmOrig("Access denied.")
        else:
          pmOrig("Syntax: !addtrust <nick> <host>")
      of "!remtrust":
        if words.len > 2:
          if isUserTrusted(state, event.nick, event.host):
            if state.settings.trustedUsers.delTrust(words[1], words[2]):
              saveSettings(state)
              pmOrig("Done.")
            else:
              pmOrig("Could not find user")
          else:
            pmOrig("Access denied.")
        else:
          pmOrig("Syntax: !remtrust <nick> <host>")
      of "!trusted":
        pmOrig("Trusted users: " & $state.settings.trustedUsers)
      of "!addrepo":
        if words.len > 2:
          if isUserTrusted(state, event.nick, event.host):
            state.settings.announceRepos.addDup(words[1] & "/" & words[2])
            saveSettings(state)
            pmOrig("Done.")
          else:
            pmOrig("Access denied.")
        else:
          pmOrig("Syntax: !addrepo <user> <repo>")
      of "!remrepo":
        if words.len > 2:
          if isUserTrusted(state, event.nick, event.host):
            if state.settings.announceRepos.del(words[1] & "/" & words[2]):
              saveSettings(state)
              pmOrig("Done.")
            else:
              pmOrig("Repo not found.")
          else:
            pmOrig("Access denied.")
        else:
          pmOrig("Syntax: !remrepo <user> <repo>")
      of "!repos":
        pmOrig("Announced repos: " & state.settings.announceRepos.join(", "))
      of "!addnick":
        if words.len > 1:
          if isUserTrusted(state, event.nick, event.host):
            state.settings.announceNicks.addDup(words[1])
            saveSettings(state)
            pmOrig("Done.")
          else:
            pmOrig("Access denied.")
        else:
          pmOrig("Syntax: !addnick <nick>")
      of "!remnick":
        if words.len > 1:
          if isUserTrusted(state, event.nick, event.host):
            if state.settings.announceRepos.del(words[1]):
              saveSettings(state)
              pmOrig("Done.")
            else:
              pmOrig("Nick not found.")
          else:
            pmOrig("Access denied.")
        else:
          pmOrig("Syntax: !remnick <nick>")
      of "!nicks":
        pmOrig("Announce nicks: " & state.settings.announceNicks.join(", "))
      
      if words[0].startswith("!kirbyrape"):
        pmOrig("(>^(>O_O)>")
      
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

proc open(port: TPort = TPort(5123)): PState =
  var cres: PState
  new(cres)
  cres.dispatcher = newDispatcher()
  cres.settings.initSettings()
  if existsFile("nimbot.json"):
    load(newFileStream("nimbot.json", fmRead), cres.settings)
  
  cres.hubPort = port
  cres.hubConnect()

  # Connect to the irc server.
  let ie = proc (irc: var TAsyncIRC, event: TIRCEvent) =
             handleIrc(irc, event, cres)
  var joinChannels = joinChans
  joinChannels.add(cres.settings.announceChans)
  cres.ircClient = AsyncIrc(ircServer, nick = botNickname, user = botNickname,
                 joinChans = joinChannels, ircEvent = ie)
  cres.ircClient.connect()
  cres.dispatcher.register(cres.ircClient)

  cres.dbConnected = false

  cres.logger = newLogger()
  result = cres

var state = ircbot.open() # Connect to the website and the IRC server.

while state.dispatcher.poll():
  if state.dbConnected:
    state.database.keepAlive()

