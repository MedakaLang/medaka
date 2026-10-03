# demo

Two small edge-plugin programs written to show how Medaka's effect system bounds what a
plugin can do. Each declares host capabilities as `extern`s with effect labels and is checked
against a policy of allowed effects.

- `plugin_good.mdk` is well behaved: it uses only `<Cache, Log, FFI>`, which the policy allows.
- `plugin_malicious.mdk` is a deliberately hostile example. It looks like analytics but
  exfiltrates a session cookie through a chain of helpers, which makes it use the `Fetch`
  effect. The policy does not allow `Fetch`, so the policy check rejects it, naming the chain
  `transform → tagVisit → recordMetric → sendBeacon → fetch`. Nothing in it
  runs against a real network; it is a test input, not a payload.

Try it with the entry function `transform`. `FFI` is in the allow list because both plugins
reach the host through `extern`s, which carry the `FFI` label; without it both are rejected
for that reason alone, and the malicious one stops at `cacheSet` before reaching the real
exfiltration chain.

```sh
medaka check-policy demo/plugin_good.mdk --allow Cache,Log,FFI --fn transform
# accepted. transform requires only <Cache, FFI, Log>

medaka check-policy demo/plugin_malicious.mdk --allow Cache,Log,FFI --fn transform
# rejected. transform requires <Cache, FFI, Fetch>. Not permitted by policy {Cache, Log, FFI}
#    reached via: transform → tagVisit → recordMetric → sendBeacon → fetch
```
