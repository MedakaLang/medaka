# The Medaka AT Protocol PDS

_Valerie Grasley · October 1, 2026_

<!-- description: A Bluesky PDS written entirely in Medaka, a functional language that didn't exist four months ago: hand-rolled crypto, new integer types, and effects that prove what the server can touch. -->
<!-- og-image: pds-card.jpg -->
<!-- og-image-alt: The Medaka fish and the Bluesky butterfly side by side. -->

Two weeks ago I made an unassuming post from a Bluesky account for my programming language Medaka:

<blockquote class="bluesky-embed" data-bluesky-uri="at://did:web:pds.medaka-lang.dev/app.bsky.feed.post/3mvo6zjwtok2k" data-bluesky-cid="bafyreigslc4ipgdqaabuil3tqaziokvjxujawbkqhzus3sl24cojgciav4"><p lang="en">println &#34;Hello world!&#34;</p>&mdash; <a href="https://bsky.app/profile/did:web:pds.medaka-lang.dev?ref_src=embed">Medaka (@medaka.medaka-lang.dev)</a> <a href="https://bsky.app/profile/did:web:pds.medaka-lang.dev/post/3mvo6zjwtok2k?ref_src=embed">2026-09-16T22:32:44.987Z</a></blockquote><script async src="https://embed.bsky.app/static/embed.js" charset="utf-8"></script>

Since then I've made the occasional post from the account, mostly around language updates. But the whole time
the account has been hiding a secret. The account isn't hosted by Bluesky at all. I'm the one hosting it.

The cool thing about Bluesky is that they actually let anyone serve their own posts and store their own data.
Unlike, say, Facebook or X (RIP Twitter), your data doesn't all belong to one company. Anyone can store and
serve their own data through a Personal Data Server or PDS. All the PDS has to do is follow the AT Protocol specification
for how a PDS should behave.

The PDS behind the Medaka language account is written entirely in Medaka, from HTTP and WebSockets to
the cryptographic primitives. In total it's about 28k lines of pure Medaka, not including all of the compiler
and standard library work that also went into it. The language itself didn't exist 4 months ago. The PDS was
built off and on over the past 6 weeks, alongside ongoing compiler and language development.
All of this was enabled by coding agents, and it's hard to imagine these sorts of timelines without them.

This blog post isn't going to go super in-depth into Medaka itself. We've got a whole [guide](https://medaka-lang.dev/guide/) for that, which
I'd encourage you to check out if you're interested. High level, Medaka is a functional programming language
inspired by languages like Haskell and OCaml. Here's what it looks like:

```medaka
data Post = Post { author : String, text : String }

render : Post -> String
render (Post { author, text }) = "@\{author}: \{text}"

main = println (render Post { author = "medaka", text = "Hello world!" })
```

```medaka-expect
@medaka: Hello world!
```

It's still experimental, but I think this project shows that
it's at minimum capable of implementing some real-world programs. There are still a lot of features that I want
to implement (and a long list of open bugs that I'm working through), but the basic elements of the language are
all in place. If you only read one section, I recommend the one on effects near the end. The effects system is
one of my favorite parts of Medaka and for this project it lets us specify exactly what the server's allowed to
touch directly in its types.

## Why a PDS?

I've been working on Medaka for the past few months and I needed a good dogfooding
project for the language. Something to really kick the tires and see if it's ready to do something actually
useful instead of just being a black hole for Claude tokens. I'd seen a lot of people talking about how cool
AT Proto is when you get to know it, and I decided implementing my own PDS would be a great way to both
see how capable Medaka is of implementing a real program and learn a bit more about AT Proto.

The reason why a PDS felt like a good project is how many different areas of the language it would either test or
require me to implement. We'd need things like HTTP handling and parsing, async support in both the language
and the runtime, and, for the cryptographic primitives, lots and lots of performance-sensitive calculations
(more on that later). It was a much more ambitious program than anything I'd written in Medaka outside of maybe
the compiler itself, and a very different kind of program. The compiler reads some files, writes some output, and
exits. A PDS stays running, juggles concurrent connections, keeps its state on disk, and holds onto a
secret key that it really shouldn't leak.

## What's a PDS?

I'm trying not to make this an in-depth explainer of everything that goes on in a PDS. That probably deserves its own
dedicated blog post and I'm not sure if I'm the right person to write it. But I can offer a quick summary of what a PDS
is and how it works.

I like to think of a PDS as two basic elements: there's a repository where all your data gets stored and there's a server
that sits on top of it that connects your data to the larger AT Protocol world. Think of it like Git for posts. Much like
natural selection keeps inventing crustaceans that look and behave like crabs, software engineers keep creating new Gits.

The server hooks your individual PDS up to the broader AT Proto ecosystem. The primary way it does this is by connecting with
relays. A relay takes a bunch of PDSes and bundles them up into one big data stream. Then individual applications (AppViews in AT Proto parlance)
can take that big data stream and build on top of it. The post above is rendered by Bluesky's AppView, which
gets the post from a relay connected to my Medaka PDS.

For fans of technical acronyms there's a lot going on under the hood, including the likes of MSTs, CAR files, and DAG-CBOR
to name just a few. Similar to Git, the PDS spec uses hashing extensively. Everything in the repo is content-addressed by its hash value. Every
commit to the PDS is cryptographically signed to prove that your posts came from you and didn't get altered by anyone along the
way. In the next section we explore these cryptographic primitives a bit further.

## Crypto

PDS crypto involves two basic functions in various different configurations: hashing and signing. Hashing is a data
fingerprint. It turns any amount of data into a short summary value that looks random from the outside, so you can't
learn anything about the data from it, and changing any part of the data gives you a completely unrelated hash.
Signing allows us to prove that some information came from someone holding a particular private key. Through the magic
of cryptography, anyone with the matching public key can tell if something was signed by the private key, but they can't
work out what the private key is or use the public key to sign things themselves.

The hash function AT Proto uses is SHA-256. The PDS also uses HMAC for session tokens and PBKDF2 for the account password,
but both of those are built out of SHA-256 too, so it's kind of SHA-256 all the way down. (I'm forced to use SHA-1 in exactly one spot in the PDS
because the relay connection runs over a WebSocket, and the WebSocket standard requires SHA-1 for its handshake.)

Signing uses ECDSA over an elliptic curve called secp256k1, which is incidentally the same curve Bitcoin uses. This is where the real work
was. Elliptic curve math means doing arithmetic on 256-bit numbers, and when I started on the PDS, Medaka had exactly one 63-bit-wide
integer type, so that needed some big language changes.

### Roll Your Own!

As we all know, the best way to approach cryptography is to roll your own. This is a reasonable decision that
no one has ever regretted. Certainly I wasn't going to be the first.

So why did I decide to break the cardinal rule of cryptography and roll my own? Was I truly drunk off of
AI coding agents to the extent that I would attempt to vibecode my own cryptographic primitives in
a language that didn't even exist a few months ago? Maybe a little bit.

Now that all of the security professionals have turned off their computers in complete disgust, allow me
to actually explain why I decided to roll my own crypto. The primary reason is for dogfooding Medaka. Cryptography is very particular and involves _a lot_ of performance-sensitive calculations
that no Medaka program had ever attempted. If we could do crypto even reasonably well, it was probably a
good sign that the language's ability to handle these kinds of computational workloads was in a decent place.

I'm also trying to be pretty open about the risks involved. Ultimately, if there's some sort of
big security hole in the PDS's crypto, the only thing affected is my Bluesky account. To be clear, it would
be pretty annoying if my account got compromised, but probably not catastrophic. Certainly not something
like leaking my credit card number. And because I'm the only one using the PDS I'm the only one who has to
pay for my hubris if a major security hole does appear. The blast radius is fairly limited even in the worst
case, so I'm okay accepting that risk.

### How Secure is it Really?

Now, the question of how secure these crypto primitives really are is a pretty interesting one.
The testing around these primitives helps me to feel like the Medaka crypto
primitives I implemented are at least decently secure. If I had to put money on it I'd say they likely have a number
of smaller undiscovered security bugs, since those seem to appear even in libraries maintained by actual cryptographers
and security experts. But I feel fairly confident that they don't have any major security holes.

The nice thing about crypto
is you can use the Super Secure Big Boy Libraries to check your work. If your SHA-256 always outputs the same
values that NIST says it should, that's a pretty good sign. The rule for the crypto primitives
in this project is that they must be checked against trusted outside sources that are assumed to be correct.
It gives us a reliable answer key when evaluating whether the functions actually do what they're supposed to do.
The answers never come from inside the project—they always originate from a trusted third party.

The answer keys come from:

- **SHA-256:** NIST's official validation vectors, the same ones used to certify SHA-256 implementations, plus the
  worked examples from the SHA-256 standard itself. That includes NIST's "Monte Carlo" test, which chains 100,000
  hashes together, each one built from the ones before it.
- **HMAC and PBKDF2:** Wycheproof's test suites for both, plus the PBKDF2 test vectors published in RFC 7914.
- **Elliptic curve math:** nearly 2,000 test cases generated by libsecp256k1, the library Bitcoin Core uses, pinned
  to a specific release.
- **Signatures:** checked against both libsecp256k1 and the signing code in Bluesky's own PDS, plus Wycheproof's
  ECDSA suites for secp256k1, which are built specifically to catch known attacks and edge cases.
- **Everything else in the repo:** the MSTs, CAR files, and repository data are checked against output from Bluesky's
  own code, generated inside the official PDS Docker image pinned to an exact version. The tokens my PDS mints for
  other services are checked by Bluesky's own verifier.

The cool—or annoying, depending on how you look at it—thing about crypto is that it's actually not enough for it to
produce the same outputs on the same inputs as the reference. We also have to worry about side-channel attacks.
Basically, it's not enough in crypto to produce the right output, you also have to produce it in the right way.
Producing it in the wrong way can lead to bits of information leaking out through things like how long it takes
your cryptographic function to run. This is where coding agents really came in handy, because I am not enough of a low-level
programming wizard to write anything that always executes in the same amount of time regardless of input.

We want to be sure that our Medaka implementation of secp256k1 doesn't leak any bits of information in how it runs.
To do this, we borrowed a fun little trick that Google's Adam Langley originally came up with. We can use Valgrind's Memcheck
tool to find if the Medaka code ever makes decisions or looks up memory based off of the secret value. Normally this tool
lets you check to see if you're making decisions based off of undefined memory. But if we tell Memcheck that the secret
key is undefined memory, it should alert us to the most common kinds of constant-time violations that would leak bits of information.
So what we do is we run Memcheck on the compiled signing code with the secret key treated as undefined memory. If Memcheck says
we never branch or look up memory based on the secret key, we can be pretty confident the signing code runs in constant time regardless of
the actual value of the secret.

We also test this the other way to make sure it can actually catch leaks. We do this by modifying the signing code with
deliberate leaks that we've planted and then making sure that Memcheck correctly identifies them. For example, we switch
a `U64` subtraction on the secret value to an `Int` subtraction (more on Medaka's integer types later). Because Medaka's
`Int` type traps on overflow, this adds a hidden branch based on the value of the secret, which Memcheck correctly flags.

Is it possible the agents I worked with overlooked something? Yeah, in fact I'd say it's fairly likely. That's why
rolling your own crypto is normally not a great idea. There are so many weird little side-channel attacks and edge cases.
But if I had to guess they're most likely of the "dedicated attacker wants to spend a lot of time and effort cracking them"
variety. Which is, you know, bad if you're using the cryptography to store sensitive personal information, but
probably fine if it's just keeping your posts safe. If anyone out there wants to use these in something that actually
matters, you have been warned. _Caveat emptor_.

Here's an honest assessment of the current blind spots:

- **No cryptographer has reviewed this.** Everything above is just testing. Nobody with real crypto expertise has read
  through the code, and that's a major shortcoming of the current state of the project.
- **Memcheck only sees branches and memory lookups.** It can't see instructions whose running time depends on
  their inputs, like division or some multiplications on certain CPUs. Hardware-level attacks like speculative
  execution and physical ones like power analysis are out of scope too, as they are for nearly all software checks.
- **The garbage collector is switched off during the check.** Medaka's garbage collector scans memory and makes
  decisions based on what each value looks like, so a number derived from the key sitting in memory could in
  principle influence it. That's a known gap that hasn't been measured yet.
- **The Memcheck check only covers the signing key.** The session-token secret and the password check use a
  constant-time comparison function, but it isn't under the same Memcheck test.
- **Only the native build is covered.** The constant-time claim is for the compiled native binary, which is what
  actually runs the PDS. The interpreter and the WebAssembly build make no such promise.
- **It's a sample.** Memcheck runs three test keys on one machine architecture, in a test binary that's linked
  slightly differently from the deployed one. Constant-time code should take the same path for every key, so
  this matters less than it sounds, but it's still a sample.

## Fun with Numbers

As alluded to above, we started this project with just two numerical types in Medaka: `Int` and `Float`.
The original version of the PDS library and its cryptographic primitives did some impressive code
gymnastics in order to make the 63-bit `Int`s work for a number of things they weren't particularly
well-suited to. But when you only have one real integer type in the language that's kind of what you're
stuck with. So the original Medaka PDS was littered with all sorts of twisted abominations: 63-bit `Int`s as bytes,
arrays of `Int`s as bytestrings, 32-bit math that had to be masked after every operation, 64-bit words represented as 4 16-bit
`Int` pieces because 63-bit `Int`s could overflow, etc. It was a mess. If you've used coding agents enough you'll
know they have a habit of dutifully coding around these sorts of obstacles, even if the resulting code is, shall
we say, less than ideal.

So it was clearly time to add an actual set of integer types to the language, as well as actual representations for
bytestrings. This is one of the areas where the dogfooding hypothesis paid off the most. We went from a pretty impoverished
set of numerical representations to a full complement of integer types: `U8`, `U16`, `U32`, `U64`, `I32`, and `I64`. We also
added a dedicated `Bytes` type for dealing with bytestrings, forever banishing arrays of `Int`s. We also got proper semantics
out of the new integer types. `U` types like `U64` are for bit representations and wrap, while `Int` now traps on overflow instead of silently wrapping around, which in ordinary arithmetic is a bug
waiting to happen.
There was also some cool compiler work that went into this. We had to optimize the compiler for the new integer representations
so we could use things like actual 32-bit instructions when dealing with 32-bit words.

The end result was some massive improvements. The code was much cleaner and types meant what they said, and we also got some
big performance gains from no longer abusing the `Int` type and using proper representations and instructions. And the integer types
took about 3 days from design to done, which is truly insane for a language feature of this scope.

Here's how things compare from just before the integer work started to today. Signing a commit went from
about 23.5 ms to about 5.3 ms, and hashing one 64-byte SHA-256 block from 2.6 µs to 0.95 µs. The rest of
the speedups, as ratios:

| What | Faster |
|---|---|
| Signing a commit (one ECDSA signature) | **5.7×** |
| SHA-256, per 64-byte block | **2.7×** |
| Password hash (PBKDF2) | **2.6×** |
| Field multiplication (the core curve operation) | **6.9×** |
| Modular inversion (one step of signing) | **30×** |
| Exporting or reloading a 2,000-record repo | **1.7×** |
| Inserting 2,000 records into the MST | **1.2×** |

_Speedups are ratios of CPU instruction counts; the two timings above are the best of five runs._

For calibration, 5.3 ms per signature is still roughly a hundred times slower than libsecp256k1. That's a
pure-Medaka implementation with no hand-written assembly, signing one commit per post, so I'm fine with it.

## Effects

Effects are one of Medaka's most distinctive features, and it's the one you're most likely to be unfamiliar
with coming from other languages. Medaka's effects system lets you describe what side effects a program
is allowed to perform and have it be checked and certified by the typechecker.

Let's start with a simple illustration:

```medaka-nocheck: an excerpt, not a whole program
greet : String -> <Stdout> Unit
greet name = println "Hello, \{name}!"
```

`println` carries a `<Stdout>` effect that signals that it can access stdout to print something. Effects
are inferred by the typechecker like normal types, but if you annotate a type and leave off the effect it's
a type error. Anything that calls `greet` also needs a `<Stdout>` effect. Medaka has built-in effects for
all sorts of side effects, like interacting with the filesystem, making network calls, etc. If your type
doesn't carry the proper effects, then you're prevented from executing them by the compiler.

I find this is especially relevant in a world of AI coding agents. One thing I often find myself wondering
about AI-generated code is "What does this even do?" Agents can generate a lot of code, and it can be
a pretty daunting task to figure out what all of that code is doing. Tracking side effects in the program
type gives you a way to set some reasonable upper bounds on what a program is capable of. A program that
doesn't have the `Net` effect can't call the network, so you know it's not something you have to worry about.
It gives humans a way to see at a glance what complex programs are capable of.

Let's take a look at how we can use effects to make guarantees about our PDS.

### Gotta Keep 'Em Separated

Almost all of the PDS lives behind one function:

```medaka-nocheck: an excerpt, not a whole program
handle : Server e -> RequestContext -> Store -> Request -> <e> (Store, Response)
```

`handle` takes the server's current state and a request, and gives back the new state and a response. Pretty simple! We love
a state machine. Behind it is about 20,000 lines of code: routing, authentication, record validation, updating the repository's tree,
building and signing commits, encoding CAR files. If you look at the type, `handle` can't do any I/O at all.
There's no `FileRead`, `Net`, or `Clock` anywhere in its type, just `e`, which represents
whatever the server's request handlers are allowed to do.

All of the actual I/O lives in a separate, much smaller layer (about 8,000 lines) that performs the side effects
the PDS needs in order to run. A nice side effect of this split is that the whole request path can be tested without a network or
a disk.

### Roll Your Own! Pt. 2

`Stdout` and `FileRead` are built into Medaka, but you can also declare your own. The PDS declares three:

```medaka-nocheck: an excerpt, not a whole program
export effect Sign Set   -- spends the account's signing key, for some purpose
export effect Mint Set   -- issues a session token
export effect Kdf        -- runs the password hash
```

Like all effects in Medaka, these are type-level constructs that the compiler erases, so they cost nothing at
runtime. Once declared, they behave exactly like the built-in effects do.

Here's how the signing key gets used:

```medaka-nocheck: an excerpt, not a whole program
signCommitDigest : SecretKey ->
  Bytes ->
  <Sign "commit"> Result String Signature

signServiceAuthDigest : SecretKey ->
  Bytes ->
  <Sign "service-auth"> Result String Signature
```

`SecretKey` is an opaque type, so only the signing module can look inside it. That's the same property the
compile-fail forgery tests from the crypto section check. The rest of the program can only use the key through
functions like these, and each one's type records what it signed, so every caller's type does too. There's also a test that fails if any
other module imports the raw signing code directly, so there's no back door around the label.

Put all of that together and you get the type of the server this PDS actually runs:

```medaka-nocheck: an excerpt, not a whole program
pdsServer : Account ->
  ServerLinks ->
  String ->
  Result String (Server <Mint {"access", "refresh"}, Sign "commit">)
```

In plain English: answering a request can issue access and refresh tokens and sign commits, and that's it.
You can also use the compiler's `check-policy` feature to check the effects of individual endpoints. Here it confirms that the read-only routes don't sign
anything, and that record writes need to sign commits, so a policy that only allows service-auth signing turns them
away:

```
$ medaka check-policy pds/lib/handlers.mdk --fn readHandled --allow ''
accepted. readHandled requires only pure
   no sample run: 'readHandled' is not a String -> String entry

$ medaka check-policy pds/lib/handlers.mdk --fn recordHandled --allow Sign=service-auth
rejected. recordHandled requires <Sign {"commit"}>. Not permitted by policy {Sign "service-auth"}
   reached via: recordHandled → applyBatchWrites
```

### Filesystem and Network Effects

Part of what makes Medaka's effects really powerful is that they're not just broad categories. They can carry specific details
about what the effects touch (or don't). For example, `readFile` is declared like this:

```medaka-nocheck: an excerpt, not a whole program
readFile : (path : String) -> <FileRead path> Result String String
```

If you want to read the file `"data/head"` you need an accompanying `<FileRead "data/head">` effect. If part of the path is only known at runtime,
the compiler understands patterns and uses those instead of an exact filepath. Here's what happens when a function that reads block files forgets to say
so:

```
$ medaka check paths.mdk
error: paths.mdk:2:25: Effectful value used where <> is allowed, but it performs <FileRead "data/blocks/*">
  |
2 | loadBlock cid = readFile ("data/blocks/" ++ cid)
  |                          ^
```

Network access works the same way. The server listens on exactly one address, and we can express that in its type:

```medaka-nocheck: an excerpt, not a whole program
listenAddress : String @"127.0.0.1"
listenAddress = "127.0.0.1"

bindAddress : Int -> <Net "127.0.0.1"> Result String (Listener "127.0.0.1")
```

`String @"127.0.0.1"` is a string whose exact value the compiler knows, and every connection that comes in through
that listener is charged `<Net "127.0.0.1">`. The server is only ever reached through a reverse proxy running on
the same machine. We get a guarantee in the type that the server itself can only talk to localhost. The outbound calls a PDS does
need to make, like reaching relays and Bluesky's AppView, go through a second proxy on the same machine that I control.

### Manifests and Sandboxes

This is where we put it all together. `medaka manifest` prints the complete list of what a program is allowed
to do, as worked out by the compiler. Here it is for `serve`, the entry point the PDS runs:

```
$ medaka manifest pds/serve.mdk --fn serve
[package.capabilities]
Clock = true
FileRead = ["data/*", "secrets/key.hex", "secrets/password", "secrets/token.hex"]
FileWrite = "data/*"
Kdf = true
Mint = ["access", "refresh"]
Net = "127.0.0.1"
Rand = true
Sign = ["commit", "service-auth"]
Signal = true
Stderr = true
Stdout = true
```

And here's the corresponding part of the systemd unit that runs it:

```
WorkingDirectory=/opt/pds
ProtectSystem=strict
ReadWritePaths=/opt/pds/data
ReadOnlyPaths=/opt/pds/secrets
IPAddressDeny=any
IPAddressAllow=localhost
```

For writing files and talking to the network, these say the same thing from two different directions. The
operating system enforces the sandbox at runtime, but the compiler already proved that the server only touches what it should before the
binary even existed. From there, it was pretty trivial to write a test that reads the systemd unit, turns it into a policy, and asks the compiler whether `serve`
fits inside it. If you narrow the unit, say by only allowing writes to `data/blocks`, the test fails. The manifest
itself is checked into the repo too, so any change that widens the server's capabilities shows up as a diff in
code review.

For reading files, the compiler is actually stricter than the sandbox. `ProtectSystem=strict` still leaves most of
the filesystem readable, but the manifest says the server only ever reads from `data/` and three specific files in
`secrets/`.

### Caveats

Same as with the crypto, we have some honest caveats:

- **These are upper bounds.** A manifest says what the server could do, not what it will do on any given request.
- **`Net` only knows about addresses.** `"127.0.0.1"` limits which addresses the code passes around, not which
  ports, and host names aren't normalized.
- **A custom effect is only as trustworthy as the module that defines it.** `Sign` means something because
  `SecretKey` is opaque and only one module can open it. The built-in effects are enforced by the compiler
  and standard library, but for custom effects you need to trust that the implementer didn't leave any holes
  or bugs that let you execute an effect without the corresponding effect type.

## Conclusion

So there it is. All of that to serve that `println "Hello world!"` post from the beginning. Pretty cool stuff
if you ask me.

One big recurring theme was how to work together with agents in a way in which you can actually trust their outputs.
Agents are insanely powerful, but they present problems in terms of keeping up with the sheer amount of code they can
churn out, as well as trusting that said code does what you want it to. I think techniques like the Valgrind memory checks
or Medaka's capability manifests are going to become increasingly necessary as we go further into this new AI-enabled
world.

So where do we go from here? Well, for the PDS I'd like to keep adding features, like the ability to support more than
one account, or support for the did:plc method (right now I'm just using the more basic did:web). I'm also interested in
playing around with other elements of the AT Proto ecosystem. As for Medaka, there's a seemingly endless amount of things
I'd like to work on in the compiler and standard library. I'm making steady progress on improving the language every week,
so be sure to check back often if the language interests you.

This post also just couldn't cover all of the cool things about this project, including things like Medaka's async language features
and runtime. A topic for another blog post maybe. I'd encourage people who are interested to check out some of the other Medaka resources,
including the [playground](https://medaka-lang.dev/) (the whole compiler right in your browser!), the [guide](https://medaka-lang.dev/guide/),
the [standard library](https://medaka-lang.dev/stdlib/), the [effects documentation](https://medaka-lang.dev/advanced/), and the
[GitHub repo](https://github.com/MedakaLang/medaka). All of the code for the PDS itself can be found
[here](https://github.com/MedakaLang/medaka/tree/main/pds). Follow the official language
[Bluesky account](https://bsky.app/profile/medaka.medaka-lang.dev) for
news and updates (and now you can take comfort in knowing that all of its posts are backed by questionably vibecoded crypto).

Until next time.
