// host_profile_table.mjs -- print the host's profile table, one fact per line, for
// compiler/types/target_profile_host_test.mdk to compare with compiler/types/target_profile.mdk
// and with the effect rows of stdlib/runtime.mdk.
//
//   G <profile> <granted labels, sorted>
//   N <slice> <p|-> <needs, sorted>             p marks a process-only slice
//   X <slice> <externs>                         the runtime.mdk externs the slice serves
//   O <profile> <slice> <real|withheld>         observed by calling one of the slice's own keys
//
// A slice with no keys has nothing to call and is not listed under O.  A key shared with
// another slice cannot tell the two apart, so the probe uses a key only this slice lists.
import { SLICES, PROFILES, createHost, CapabilityError } from '../../playground/medaka_host.mjs';

const own = (slice) => SLICES[slice].keys.find((k) =>
  Object.entries(SLICES).every(([n, s]) => n === slice || !s.keys.includes(k)));

const observe = (profile, slice) => {
  const f = createHost(profile, { stdin: () => new Uint8Array(0) }).imports.env[own(slice)];
  // A promise-answering key installed without a promising entry raises the JSPI
  // CapabilityError: the slice is real, only this engine cannot wait.
  try { f(0); } catch (e) {
    if (e instanceof CapabilityError && !e.message.includes('needs JSPI')) return 'withheld';
  }
  return 'real';
};

for (const [p, { grants }] of Object.entries(PROFILES))
  console.log(['G', p, ...[...grants].sort()].join(' '));
for (const [n, s] of Object.entries(SLICES))
  console.log(['N', n, s.process ? 'p' : '-', ...[...s.needs].sort()].join(' '));
for (const [n, s] of Object.entries(SLICES))
  console.log(['X', n, ...(s.externs || [])].join(' '));
for (const p of Object.keys(PROFILES))
  for (const [n, s] of Object.entries(SLICES))
    if (s.keys.length > 0) console.log(['O', p, n, observe(p, n)].join(' '));
