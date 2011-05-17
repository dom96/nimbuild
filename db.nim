# This module is used by the website.
import redis, times, strutils
from sockets import TPort

type
  TDb* = object
    r: TRedis
    lastPing: float

  TBuildResult* = enum
    bFail, bSuccess

  TTestResult* = enum
    tFail, tSuccess

  TPlatforms* = seq[TCommit]
  
  TCommit* = object
    buildResult*: TBuildResult
    testResult*: TTestResult
    failReason*, platform*, hash*: string

const
  listName = "commits"
  dbPort* = TPort(6379)
  failOnExisting = False

proc open*(host = "localhost", port = dbPort): TDb =
  result.r = redis.open(host, port)
  result.lastPing = epochTime()

proc customHSet(database: TDb, name, field, value: string) =
  if database.r.hSet(name, field, value).int == 0:
    if failOnExisting:
      assert(false)
    else:
      echo("[Warning:REDIS] ", field, " already exists in ", name)

proc addCommit*(database: TDb, commitHash, platform: string) =
  var name = platform & ":" & commitHash
  if database.r.exists(name):
    if failOnExisting: quit("[FAIL] " & name & " already exists!", 1)
    else: echo("[Warning] " & name & " already exists!")
  
  # Add the commit hash to the `commits` list.
  discard database.r.lPush(listName, commitHash)
  # Add this platform to `commitHash:platforms` list.
  discard database.r.lPush(commitHash & ":" & "platforms", platform)

proc updateProperty*(database: TDb, commitHash, platform, property,
                    value: string) =
  var name = platform & ":" & commitHash
  if database.r.hSet(name, property, value).int == 0:
    echo("[INFO:REDIS] 1 field updated in hash")
  else:
    echo("[INFO:REDIS] 1 new field added to hash")

proc keepAlive*(database: var TDb) =
  ## Keep the connection alive. Ping redis in this case. This functions does
  ## not guarantee that redis will be pinged.
  var t = epochTime()
  if t - database.lastPing >= 60.0:
    echo("PING -> redis")
    assert(database.r.ping() == "PONG")
    database.lastPing = t
    
proc getCommits*(database: TDb,
                 platforms: var seq[string]): seq[TPlatforms] =
  result = @[]
  for c in items(database.r.lrange("commits", 0, -1)):
    var platformsRaw = database.r.lrange(c & ":platforms", 0, -1)
    var commitPlatforms: TPlatforms = @[]
    for p in items(platformsRaw):
      var commit: TCommit
      for key, value in database.r.hashIterAll(p & ":" & c):
        case key
        of "buildResult":
          commit.buildResult = parseInt(value).TBuildResult
        of "testResult":
          commit.testResult = parseInt(value).TTestResult
        of "failReason":
          commit.failReason = value
        else:
          assert(false)
      
      commit.platform = p
      commit.hash = c
      echo(c)
      commitPlatforms.add(commit)
      if p notin platforms:
        platforms.add(P)
    result.add(commitPlatforms)
  assert(result.len > 0)

proc `[]`*(cPlatforms: TPlatforms, p: string): TCommit =
  for c in items(cPlatforms):
    if c.platform == p:
      return c
  raise newException(EInvalidValue, p & " platforms not found in commits.")
  
    
    
    


