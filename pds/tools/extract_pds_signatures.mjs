import fs from 'node:fs'
import { Secp256k1Keypair } from '/app/node_modules/.pnpm/@atproto+crypto@0.5.4/node_modules/@atproto/crypto/dist/secp256k1/keypair.js'

const manifest = fs.readFileSync(process.argv[2], 'utf8')
const lines = manifest.split('\n').filter((line) => line && !line.startsWith('#'))
const keys = new Map()
for (const line of lines) {
  const fields = line.split(/\s+/)
  if (fields[0] === 'key') keys.set(Number(fields[1]), fields[2])
}
for (const line of lines) {
  const fields = line.split(/\s+/)
  if (fields[0] !== 'pds') continue
  const [_, id, keyId, message, digest] = fields
  const key = keys.get(Number(keyId))
  const pair = await Secp256k1Keypair.import(key, { exportable: false })
  const publicKey = Buffer.from(pair.publicKeyBytes()).toString('hex')
  const signature = Buffer.from(await pair.sign(Buffer.from(message, 'hex'))).toString('hex')
  console.log(`pds-oracle ${id} ${key} ${message} ${digest} ${publicKey} ${signature}`)
}
