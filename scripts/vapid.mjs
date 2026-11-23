#!/usr/bin/env node
// Prints a new VAPID key pair for Web Push. Put both lines into .env (and .env.test); keep the private one secret.
//   node scripts/vapid.mjs
import { generateKeyPairSync } from 'node:crypto';
const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const pub = publicKey.export({ format: 'jwk' }), prv = privateKey.export({ format: 'jwk' });
const raw = Buffer.concat([Buffer.from([4]), Buffer.from(pub.x, 'base64url'), Buffer.from(pub.y, 'base64url')]).toString('base64url');
console.log(`VAPID_PUBLIC_KEY=${raw}\nVAPID_PRIVATE_KEY=${prv.d}\nVAPID_SUBJECT=mailto:you@example.com`);
