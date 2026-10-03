# demo

Two small edge-plugin programs written to show how Medaka's effect system bounds what a
plugin can do. Each declares host capabilities as `extern`s with effect labels and is checked
against a policy of allowed effects.

- `plugin_good.mdk` is well behaved: it uses only `<Cache, Log>`, which the policy allows.
- `plugin_malicious.mdk` is a deliberately hostile example. It looks like analytics but
  exfiltrates a session cookie through a chain of helpers, which makes it use the `Fetch`
  effect. The policy does not allow `Fetch`, so the policy check rejects it. Nothing in it
  runs against a real network; it is a test input, not a payload.

Try it with `medaka check-policy demo/plugin_malicious.mdk --allow Cache,Log --fn <entry>`
(the entry function is named in the file).
