import irc, sockets, json, os


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


proc handleWebMessage(state: var TState, line: string) =
  echo("Got message from hub: " & line)
  var json = parseJson(line)
  if json.existsKey("payload"):
    for commit in items(json["payload"]["commits"]):
      # Create the message
      var message = ""
      message.add(commit["id"].str[0..6] & " ")
      message.add(commit["author"]["name"].str & " ")
      message.add("[+" & $commit["added"].len & " ")
      message.add("±" & $commit["modified"].len & " ")
      message.add("-" & $commit["removed"].len & "]: ")
      message.add(commit["message"].str)

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
      state.ircClient.connect()
    of EvMsg:
      echo("< ", event.raw)
      # TODO: ... commands
