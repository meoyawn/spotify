import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';

const bundlePath = '.local/native-scripts/59a1e2bad44f35bcf8b21a86fe2e95dc216e0614e2d65cbd1a8ad75c1d8ea79f.js';
const source = fs.readFileSync(bundlePath, 'utf8');
const headers = [...source.matchAll(/(?:^|,)(\d+)\([a-z,]*\)\{/g)];
const factories = new Map();
for (let index = 0; index < headers.length; index++) {
  const start = headers[index].index + (source[headers[index].index] === ',' ? 1 : 0);
  factories.set(Number(headers[index][1]), source.slice(start, headers[index + 1]?.index ?? source.length));
}
const cache = new Map();
const retained = [];

function load(id) {
  if (cache.has(id)) return cache.get(id).exports;
  const body = factories.get(id);
  if (!body) throw new Error(`Missing original factory ${id}`);
  const module = {exports: {}};
  cache.set(id, module);
  let executable = body;
  if (id === 13749) {
    const marker = body.indexOf('SERVICE_ID="spotify.collection_esperanto.proto.CollectionService"');
    const name = [...body.slice(0, marker).matchAll(/class ([\w$]+)\{/g)].at(-1)[1];
    executable = `${body.slice(0, -1)};t.originalCollectionClient=${name};}`;
  }
  const factory = vm.runInNewContext(`({${executable}})[${id}]`, {console, Uint8Array, ArrayBuffer, TextEncoder, TextDecoder, URL, self: load.g});
  retained.push({module: id, sha256: crypto.createHash('sha256').update(body).digest('hex')});
  factory(module, module.exports, load);
  return module.exports;
}
load.d = (target, getters, values = {}) => {
  for (const [name, get] of Object.entries(getters)) Object.defineProperty(target, name, {get, enumerable: true});
  for (const [name, value] of Object.entries(values)) Object.defineProperty(target, name, {value, enumerable: true});
};
load.n = value => value?.__esModule ? () => value.default : () => value;
load.o = (value, key) => Object.hasOwn(value, key);
load.r = target => Object.defineProperty(target, '__esModule', {value: true});
load.g = {Uint8Array, ArrayBuffer, Buffer, console};

const platform = factories.get(74960);
const addSource = platform.slice(platform.indexOf('async function gP('), platform.indexOf('async function gL('));
const removeSource = platform.slice(platform.indexOf('async function gL('), platform.indexOf('async function gk('));
const uriApi = load(47136);
const collection = load(13749);
const functions = vm.runInNewContext(`(${addSource})`, {i5: uriApi});
const remove = vm.runInNewContext(`(${removeSource})`, {i5: uriApi});
const bridge = [];
const service = new collection.originalCollectionClient({callSingle: async request => {
  bridge.push({service: request.service, method: request.method, payloadHex: Buffer.from(request.payload).toString('hex')});
  return new Uint8Array();
}});
const uri = 'spotify:artist:0000000000000000000001';
await functions(service, null, [uri], true, 'unused-liked-songs-uri');
await remove(service, null, [uri], true, 'unused-liked-songs-uri');
const variants = load(92250);
const report = {
  source: {application: 'Spotify macOS 1.3.6.1921', bundlePath,
    sha256: crypto.createHash('sha256').update(source).digest('hex'), modules: retained,
    libraryRouting: {module: 74960, moduleSha256: crypto.createHash('sha256').update(platform).digest('hex'),
      functions: [{name: 'gP', sha256: crypto.createHash('sha256').update(addSource).digest('hex')},
        {name: 'gL', sha256: crypto.createHash('sha256').update(removeSource).digest('hex')}]}},
  originalExecution: {artistUri: uri, bridge,
    galleryVariant: variants.t({preferFullBleed: false, galleryImage: {url: 'fixture'}, avatarImages: []}),
    avatarVariant: variants.t({preferFullBleed: false, galleryImage: null, avatarImages: [{url: 'fixture'}]})},
  scope: 'Unchanged original Library add/remove routing, URI parser, collection client and protobuf encoder execute. Gallery/avatar selection executes unchanged. No account, network, native CollectionService backend or native HTTP WRITE producer executes.',
  substitutions: ['An inert Esperanto transport captures calls and returns an empty success response.', 'A new export exposes the original CollectionService client without changing its constructor or methods.', 'The original bundled protobufjs runtime executes as a standard primitive. A synthetic artist URI is the only entity input.'],
};
fs.writeFileSync('.local/artist-about-original-execution.json', `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify(report.originalExecution));
