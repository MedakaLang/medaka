# process

## `PipeChoice`

```
data PipeChoice
  = Piped
  | Null
```

## `SpawnOptions`

```
data SpawnOptions
  = SpawnOptions { argv : List String, cwd : String, env : List (String, String), stdin : PipeChoice, stdout : PipeChoice, stderr : PipeChoice }
```

## `ProcessOperation`

```
data ProcessOperation
  = Validate
  | Pipe
  | Fork
  | Chdir
  | ExecImage
  | Wait
  | Close
  | LaunchHandshake
```

## `ProcessError`

```
data ProcessError
  = InvalidSpawn String
  | SpawnFailed ProcessOperation Int String
  | ProcessClosed
  | StillRunning
  | WaitFailed Int String
  | CloseFailed Int String
  | Unsupported String
  | LaunchCancelled
```

## `ExitStatus`

```
data ExitStatus
  = Exited Int
  | Signalled Int Bool
```

## `StartError`

```
data StartError ticket
  = StartRejected ProcessError
  | StartCleanupPending ProcessError ticket
```

## `LaunchProgress`

```
data LaunchProgress process
  = LaunchPending
  | LaunchStarted process
  | LaunchFailed ProcessError
  | LaunchAborted
```

## `start`

```
start : (program : String) -> SpawnOptions -> <Exec program> Result (StartError (LaunchTicket program)) (Process program)
start program opts
```

## `retryStart`

```
retryStart : LaunchTicket p -> <Exec p> Result (StartError (LaunchTicket p)) (Process p)
retryStart ticket
```

## `checkStart`

```
checkStart : LaunchTicket p -> <Exec p> Result ProcessError (LaunchProgress (Process p))
checkStart ticket
```

## `abortStart`

```
abortStart : LaunchTicket p -> <Exec p> Result ProcessError (LaunchProgress (Process p))
abortStart ticket
```

## `pollExit`

```
pollExit : Process p -> <Exec p> Result ProcessError (Option ExitStatus)
pollExit p
```

## `closeStdin`

```
closeStdin : Process p -> <Exec p> Result ProcessError Unit
closeStdin p
```

## `dispose`

```
dispose : Process p -> <Exec p> Result ProcessError Unit
dispose p
```

