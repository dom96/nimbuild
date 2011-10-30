import irc, sockets, json, os, strutils


type
  TState = object
    sock: TSocket
    ircClient: TIRC
    hubPort: TPort

const 
  ircServer = "irc.freenode.net"
  joinChans = @["#nimrod"]

proc parseReply(line: string, expect: string): Bool =
  var jsonDoc = parseJson(line)
  return jsonDoc["reply"].str == expect

proc hubConnect(state: var TState) =
  state.sock = socket()
  state.sock.connect("127.0.0.1", state.hubPort)

  # Send greeting
  var obj = newJObject()
  obj["name"] = newJString("irc")
  obj["platform"] = newJString("?")
  state.sock.send($obj & "\c\L")

  # Wait for reply.
  var readSocks = @[state.sock]
  if select(readSocks, 1500) == 1 and readSocks.len == 0:
    var line = ""
    assert state.sock.recvLine(line)
    assert parseReply(line, "OK")
    echo("The hub accepted me!")
  else:
    raise newException(EInvalidValue,
                       "Hub didn't accept me. Waited 1.5 seconds.")

proc open(port: TPort = TPort(5123)): TState =
  result.hubPort = port
  result.hubConnect()

  # Connect to the irc server.
  result.ircClient = irc(ircServer, nick = "NimBot", user = "NimBot",
                         joinChans = joinChans)

proc limitCommitMsg(m: string): string =
  ## Limits the message to 300 chars and adds ellipsis.
  var m1 = m
  if NewLines in m1:
    m1 = m1.splitLines()[0]
  
  if m1.len >= 300:
    m1 = m1[0..300] & "..."

  if NewLines in m: m1.add($m.splitLines().len & " more lines")

  return m1

proc handleWebMessage(state: var TState, line: string) =
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
      state.ircClient.privmsg(joinChans[0], message)

proc processWebMessage(state: var TState) =
  var readSocks = @[state.sock]
  if select(readSocks, 1) == 1 and readSocks.len == 0:
    var line = ""
    if state.sock.recvLine(line):
      # Handle the message
      state.handleWebMessage(line)
    else:
      echo("Disconnected from hub: ", OSErrorMsg())
      var connected = false
      while (not connected):
        echo("Reconnecting...")
        try:
          connected = true
          state.hubConnect()
        except:
          echo(getCurrentExceptionMsg())
          connected = false

        echo("Waiting 5 seconds...")
        sleep(5000)

var state = open() # Connect to the website and the IRC server.

while True:
  processWebMessage(state)

  var event: TIRCEvent
  if state.ircClient.poll(event):
    case event.typ
    of EvDisconnected:
      while not state.ircClient.isConnected:
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
        of "!ping": state.ircClient.privmsg(event.origin, "pong")
        of "!lag":
          if state.ircClient.getLag != -1.0:
            var lag = state.ircClient.getLag
            lag = lag * 1000.0
            state.ircClient.privmsg(event.origin,
                                    $int(lag) &
                                    "ms between me and the server.")
          else:
            state.ircClient.privmsg(event.origin, "Unknown.")

      # TODO: ... commands
