import irc, sockets, json, os


type
  TState = object
    sock: TSocket
    ircClient: TIRC

const 
  ircServer = "irc.freenode.net"
  joinChans = @["#nimrod"]

proc parseReply(line: string, expect: string): Bool =
  var jsonDoc = parseJson(line)
  return jsonDoc["reply"].str == expect

proc open(port: TPort = TPort(5123)): TState =
  result.sock = socket()
  result.sock.connect("127.0.0.1", port)

  # Send greeting
  var obj = newJObject()
  obj["name"] = newJString("irc")
  obj["platform"] = newJString("?")
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
  if select(readSocks, 200) == 1 and readSocks.len == 0:
    var line = ""
    if state.sock.recvLine(line):
      # Handle the message
      state.handleWebMessage(line)
    else:
      OSError()
  


var state = open() # Connect to the website.

# Connect to the irc server.
state.ircClient = irc(ircServer, joinChans = joinChans)
state.ircClient.connect()

while True:
  processWebMessage(state)

  var event: TIRCEvent
  if state.ircClient.poll(event):
    case event.typ
    of EvDisconnected:
      state.ircClient.connect()
    of EvMsg:
      # TODO: ...
