// host_profile_table.mjs -- print the host's profile table, one fact per line, for
// test/wasm_host_profile_agreement_test.mdk to compare with compiler/types/target_profile.mdk.
//
//   G <profile> <granted labels, sorted>
//   N <slice> <p|-> <needs, sorted>             p marks a process-only slice
//   O <profile> <slice> <real|withheld>         observed by calling one of the slice's own keys
//
// A slice with no keys has nothing to call and is not listed under O.  A key shared with
// another slice cannot tell the two apart, so the probe uses a key only this slice lists.
import { SLICES, PROFILES, createHost, CapabilityError } from '../../playground/medaka_host.mjs';

const own = (slice) => SLICES[slice].keys.find((k) =>
  Object.entries(SLICES).every(([n, s]) => n === slice || !s.keys.includes(k)));

const observe = (profile, slice) => {
  const f = createHost(profile).imports.env[own(slice)];
  try { f(0); } catch (e) { if (e instanceof CapabilityError) return 'withheld'; }
  return 'real';
};

for (const [p, { grants }] of Object.entries(PROFILES))
  console.log(['G', p, ...[...grants].sort()].join(' '));
for (const [n, s] of Object.entries(SLICES))
  console.log(['N', n, s.process ? 'p' : '-', ...[...s.needs].sort()].join(' '));
for (const p of Object.keys(PROFILES))
  for (const [n, s] of Object.entries(SLICES))
    if (s.keys.length > 0) console.log(['O', p, n, observe(p, n)].join(' '));
