import os, tables, hashes
# TODO: Rename this module to ``utils``
type
  TBuilderJob* = enum
    jBuild, jTest, jDocGen, jCSrcGen

  TProgress* = enum
    jUnknown, jFail, jInProgress, jSuccess

  TStatus* = object
    isInProgress*: bool
    desc*: string
    hash*: string
    branch*: string
    jobs*: TTable[TBuilderJob, TProgress]
    cmd*: string
    args*: string
    FTPSpeed*: float
  
  TBuilderEventType* = enum
    bProcessStart, bProcessLine, bProcessExit, bFTPUploadSpeed, bEnd, bStart

proc hash*[T: enum](x: T): THash = ord(x)

proc initStatus*(): TStatus =
  result.isInProgress = false
  result.jobs = initTable[TBuilderJob, TProgress]()
  result.desc = ""
  result.hash = ""
  result.cmd = ""
  result.args = ""
  result.FTPSpeed = -1.0

proc jobInProgress*(s: TStatus): TBuilderJob =
  assert s.isInProgress
  for j, p in s.jobs:
    if p == jInProgress:
      return j
  raise newException(EInvalidValue, "No job could be found that is in progress.")

proc findLatestJob*(s: TStatus, job: var TBuilderJob): bool  =
  for i in TBuilderJob:
    if s.jobs[i] == jFail or s.jobs[i] == jSuccess:
      job = i
      return true

proc `$`*(s: TStatus): string =
  if s.isInProgress:
    let job = jobInProgress(s)
    case job
    of jBuild:
      result = "Bootstrapping"
    of jTest:
      result = "Testing"
    of jDocGen:
      result = "Generating docs"
    of jCSrcGen:
      result = "Generating C Sources"
  else:
    var job: TBuilderJob
    result = "Unknown"
    if findLatestJob(s, job):
      case job
      of jBuild:
        if s.jobs[job] == jSuccess:
          result = "Bootstrapped successfully"
        elif s.jobs[job] == jFail:
          result = "Bootstrapping failed"
      of jTest:
        if s.jobs[job] == jSuccess:
          result = "Tested successfully"
        elif s.jobs[job] == jFail:
          result = "Testing failed"
      of jDocGen:
        if s.jobs[job] == jSuccess:
          result = "Doc generation succeeded"
        elif s.jobs[job] == jFail:
          result = "Doc generation failed"
      of jCSrcGen:
        if s.jobs[job] == jSuccess:
          result = "C source generation succeeded"
        elif s.jobs[job] == jFail:
          result = "C source generation failed"
      
  
proc makeCommitPath*(platform, hash: string): string =
  return platform / hash.substr(0, 11)  # 11 Chars.

proc makeZipPath*(platform, hash: string): string =
  return platform / "nimrod_" & hash.substr(0, 11)
