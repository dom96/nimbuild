import irc, sockets, asyncio, json, os, strutils


type
  PState = ref TState
  TState = object of TObject
    dispatcher: PDispatcher
    sock: PAsyncSocket
    ircClient: PAsyncIRC
    hubPort: TPort

const 
  ircServer = "irc.freenode.net"
  joinChans = @["#nimrod"]

proc parseReply(line: string, expect: string): Bool =
  var jsonDoc = parseJson(line)
  return jsonDoc["reply"].str == expect

proc limitCommitMsg(m: string): string =
  ## Limits the message to 300 chars and adds ellipsis.
  var m1 = m
  if NewLines in m1:
    m1 = m1.splitLines()[0]
  
  if m1.len >= 300:
    m1 = m1[0..300] & "..."

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
      message.add(commit["id"].str[0..6] & " ")
      message.add(commit["author"]["name"].str & " ")
      message.add("[+" & $commit["added"].len & " ")
      message.add("±" & $commit["modified"].len & " ")
      message.add("-" & $commit["removed"].len & "]: ")
      message.add(limitCommitMsg(commit["message"].str))

      # Send message to #nimrod.
      state.ircClient[].privmsg(joinChans[0], message)

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
  except EOS:
    echo(getCurrentExceptionMsg())
    s.close()
    echo("Waiting 5 seconds...")
    sleep(5000)
    state.hubConnect()

proc handleRead(s: PAsyncSocket, userArg: PObject) =
  let state = PState(userArg)
  var line = ""
  doAssert state.sock.recvLine(line)
  if line != "":
    # Handle the message
    state.handleWebMessage(line)
  else:
    echo("Disconnected from hub: ", OSErrorMsg())
    echo("Reconnecting...")
    state.hubConnect()

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
    if event.cmd == MPrivMsg:
      var msg = event.params[event.params.high]
      case msg
      of "!ping": state.ircClient[].privmsg(event.origin, "pong")
      of "!lag":
        if state.ircClient[].getLag != -1.0:
          var lag = state.ircClient[].getLag
          lag = lag * 1000.0
          state.ircClient[].privmsg(event.origin,
                                  $int(lag) &
                                  "ms between me and the server.")
        else:
          state.ircClient[].privmsg(event.origin, "Unknown.")

    # TODO: ... commands

proc open(port: TPort = TPort(5123)): PState =
  new(result)
  result.dispatcher = newDispatcher()
  
  result.hubPort = port
  result.hubConnect()

  # Connect to the irc server.
  result.ircClient = AsyncIrc(ircServer, nick = "NimBot", user = "NimBot",
                 joinChans = joinChans, ircEvent = handleIrc, userArg = result)
  result.ircClient.connect()
  result.dispatcher.register(result.ircClient)


var state = open() # Connect to the website and the IRC server.

while state.dispatcher.poll(): nil

