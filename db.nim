# This module is used by the website.
import redis, times, strutils
from sockets import TPort

type
  TDb* = object
    r: TRedis
    lastPing: float

  TBuildResult* = enum
    bUnknown, bFail, bSuccess

  TTestResult* = enum
    tUnknown, tFail, tSuccess

  TPlatforms* = seq[TCommit]
  
  TCommit* = object
    buildResult*: TBuildResult
    testResult*: TTestResult
    failReason*, platform*, hash*, websiteURL*, commitMsg*, username*: string
    total*, passed*, skipped*, failed*: biggestInt
    date*: TTime

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

proc updateProperty*(database: TDb, commitHash, platform, property,
                    value: string) =
  var name = platform & ":" & commitHash
  if database.r.hSet(name, property, value).int == 0:
    echo("[INFO:REDIS] '$1' field updated in hash" % [property])
  else:
    echo("[INFO:REDIS] '$1' new field added to hash" % [property])

proc addCommit*(database: TDb, commitHash, platform, commitMsg, user: string) =
  var name = platform & ":" & commitHash
  if database.r.exists(name):
    if failOnExisting: quit("[FAIL] " & name & " already exists!", 1)
    else: echo("[Warning] " & name & " already exists!")
  
  # Add the commit hash to the `commits` list.
  discard database.r.lPush(listName, commitHash)
  # Add this platform to `commitHash:platforms` list.
  discard database.r.lPush(commitHash & ":" & "platforms", platform)
  # Add the commit message, current date and username as a property
  updateProperty(database, commitHash, platform, "commitMsg", commitMsg)
  updateProperty(database, commitHash, platform, "date", $int(getTime()))
  updateProperty(database, commitHash, platform, "username", user)

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
      for key, value in database.r.hPairs(p & ":" & c):
        case normalize(key)
        of "buildresult":
          commit.buildResult = parseInt(value).TBuildResult
        of "testresult":
          commit.testResult = parseInt(value).TTestResult
        of "failreason":
          commit.failReason = value
        of "websiteurl":
          commit.websiteURL = value
        of "total":
          commit.total = parseBiggestInt(value)
        of "passed":
          commit.passed = parseBiggestInt(value)
        of "skipped":
          commit.skipped = parseBiggestInt(value)
        of "failed":
          commit.failed = parseBiggestInt(value)
        of "commitmsg":
          commit.commitMsg = value
        of "date":
          commit.date = TTime(parseInt(value))
        of "username":
          commit.username = value
        else:
          echo(normalize(key))
          assert(false)
      
      commit.platform = p
      commit.hash = c
      
      commitPlatforms.add(commit)
      if p notin platforms:
        platforms.add(P)
    result.add(commitPlatforms)

proc `[]`*(cPlatforms: TPlatforms, p: string): TCommit =
  for c in items(cPlatforms):
    if c.platform == p:
      return c
  raise newException(EInvalidValue, p & " platforms not found in commits.")
  
proc contains*(p: TPlatforms, s: string): bool =
  for c in items(p):
    if c.platform == s:
      return True
    
    


