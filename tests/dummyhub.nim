import asyncio, jester, sockets, json

var currentClient: PAsyncSocket

proc clientRead(s: PAsyncSocket) =
  var line = ""
  if s.readLine(line):
    if line == "":
      echo("Client disconnected")
      currentClient.close()
      currentClient = nil
    else:
      echo("Recv: ", line)
      var json = parseJson(line)
      if json.hasKey("ping"):
        json["pong"] = json["ping"]
        json.delete("ping")
        s.send($json & "\c\L")
      elif json.hasKey("name"):
        s.send($(%{ "reply": %"OK" }) & "\c\L")

when isMainModule:
  var disp = newDispatcher()
  var hubSock = AsyncSocket()
  hubSock.bindAddr(TPort(5123))
  hubSock.listen()
  
  hubSock.handleAccept =
    proc (s: PAsyncSocket) =
      if currentClient != nil: currentClient.close()
      currentClient = s.accept()
      currentClient.handleRead = clientRead
      disp.register(currentClient)
  disp.register(hubSock)
  
  get "/":
    if currentClient == nil: resp "No client."
    else: resp "OK"
  
  get "/boot":
    if currentClient == nil: halt "No client! :("
    var reply = newJObject()
    reply["payload"] = newJObject()
    reply["payload"]["after"] = newJString("HEAD")
    reply["payload"]["ref"] = newJString("refs/heads/master")
    reply["payload"]["commits"] = newJArray()
    reply["rebuild"] = newJBool(true)
    currentClient.send($reply & "\c\L")
    resp "We are now bootstrapping."
  
  get "/stop":
    if currentClient == nil: halt "No client! :("
    var reply = %{"do": %"stop"}
    currentClient.send($reply & "\c\L")
    resp "Stopped."
  
  disp.register()
  
  while true:
    doAssert disp.poll()
    