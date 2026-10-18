// Preload (`node --import`) that makes JSPI absent whatever the Node version:
// newer Nodes ship WebAssembly.Suspending/promising on by default, so a process
// started without the flag no longer lacks them.
delete WebAssembly.Suspending;
delete WebAssembly.promising;
