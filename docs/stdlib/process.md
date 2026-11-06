# process

Submit a bounded native launch without waiting for creation or exec.
The ticket retains cleanup ownership until checkStart transfers a Process or
abortStart positively observes terminal cleanup. Queue permits remain held
during creation and failed cleanup; callers must keep draining pending tickets.

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
  | Read
  | Write
  | StreamLookup
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
  | InvalidIO String
  | StreamFailed ProcessOperation Int String
  | SubmissionQueueFull
  | ProcessBusy
```

## `OutputStream`

```
data OutputStream
  = ChildStdout
  | ChildStderr
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

## `submit`

```
submit : (program : String) -> SpawnOptions -> <Exec program> Result ProcessError (LaunchTicket program)
submit program opts
```

Submit a bounded native launch without waiting for creation or exec.
The ticket retains cleanup ownership until checkStart transfers a Process or
abortStart positively observes terminal cleanup. Queue permits remain held
during creation and failed cleanup; callers must keep draining pending tickets.

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

## `outputStreamCode`

```
outputStreamCode : OutputStream -> Int
```

The native stream selector for an output stream.

## `tryRead`

```
tryRead : Process p -> OutputStream -> Int -> <Exec p> Result ProcessError (Option Bytes)
tryRead p stream limit
```

## `tryWrite`

```
tryWrite : Process p -> Bytes -> Int -> Int -> <Exec p> Result ProcessError (Option Int)
tryWrite p bytes offset count
```

## `streamFd`

```
streamFd : Process p -> Int -> <Exec p> Result ProcessError Int
streamFd p stream
```

