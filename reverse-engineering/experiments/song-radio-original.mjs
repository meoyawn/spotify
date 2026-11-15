import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import {parse} from '/Users/meoyawn/Developer/github/rea/node_modules/@babel/parser/lib/index.js';

const bundlePath = '.local/native-scripts/59a1e2bad44f35bcf8b21a86fe2e95dc216e0614e2d65cbd1a8ad75c1d8ea79f.js';
const source = fs.readFileSync(bundlePath, 'utf8');
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const ast = parse(source, {sourceType: 'script'});
const properties = ast.program.body[0].declarations[0].init.properties;
const ids = [53150, 39732, 83873, 41332, 87337, 47136, 69449];
const factories = new Map();
const sources = [];
for (const id of ids) {
  const property = properties.find(property => property.key.value === id);
  const text = source.slice(property.start, property.end);
  factories.set(id, vm.runInNewContext(`({${text}})[${id}]`, {URL, URLSearchParams}));
  sources.push({id, offsetBytes: Buffer.byteLength(source.slice(0, property.start)),
    lengthBytes: Buffer.byteLength(text), sha256: digest(text)});
}

const jsx = (type, props) => ({type, props});
let product = {}, online = true, requests = [], navigations = [], events = [], response;
const builderContext = {};
const substitutions = new Map([
  [23955, {jsx, jsxs: jsx}],
  [62515, {memo: component => component, useCallback: callback => callback}],
  [28625, () => ''], [80193, {E: 'Text'}], [96743, {}], [46274, {}],
  [86592, {Ru: {get: key => key}}], [96246, {D: 'MenuItem'}], [38950, {B: 'DisabledItem'}],
  [33777, {c: () => false}], [74996, {e: () => undefined}], [30057, {_: {GO_TO_RADIO: 'radio'}}],
  [25598, {g: () => path => navigations.push(path)}], [84988, {n: () => online}],
  [7540, {A: () => builderContext.builder}],
  [58032, {Tk: () => ({logEvent: event => events.push(event)})}],
  [65902, {$3: key => product[key]}], [25371, {u: name => Symbol(name)}],
]);
const cache = new Map();
function load(id) {
  if (substitutions.has(id)) return substitutions.get(id);
  if (cache.has(id)) return cache.get(id);
  const module = {exports: {}};
  cache.set(id, module.exports);
  if (!factories.has(id)) throw Error(`Missing original module ${id}`);
  factories.get(id)(module, module.exports, load);
  return module.exports;
}
load.d = (exports, getters, values = {}) => {
  for (const [key, get] of Object.entries(getters)) Object.defineProperty(exports, key, {get, enumerable: true});
  for (const [key, value] of Object.entries(values)) Object.defineProperty(exports, key, {value, enumerable: true});
};
load.n = value => () => value;
load.r = exports => Object.defineProperty(exports, '__esModule', {value: true});

const getReference = JSON.parse(fs.readFileSync('reverse-engineering/fixtures/native-renderer-lyrics.json', 'utf8'));
const inputs = [
  {name: 'ordinary song', uri: 'spotify:track:0000000000000000000001', locale: 'en'},
  {name: 'another song and locale', uri: 'spotify:track:0000000000000000000002', locale: 'de'},
  {name: 'explicitly allowed in DSA mode', uri: 'spotify:track:0000000000000000000003', locale: 'en',
    product: {'user_access_personalized_recs': '1', 'dsa-mode-enabled': '1'}},
  {name: 'personalization denied', uri: 'spotify:track:0000000000000000000004', locale: 'en',
    product: {'user_access_personalized_recs': '0'}},
  {name: 'DSA mode without personalized consent', uri: 'spotify:track:0000000000000000000005', locale: 'en',
    product: {'dsa-mode-enabled': '1'}},
  {name: 'offline', uri: 'spotify:track:0000000000000000000006', locale: 'en', online: false},
  {name: 'first returned playlist wins', uri: 'spotify:track:0000000000000000000007', locale: 'en',
    mediaItems: [{uri: 'spotify:playlist:0000000000000000000002'}, {uri: 'spotify:playlist:0000000000000000000001'}]},
];
const cases = [];
for (const input of inputs) {
  product = input.product ?? {};
  online = input.online ?? true;
  requests = []; navigations = []; events = [];
  response = {body: {mediaItems: input.mediaItems ?? [{uri: 'spotify:playlist:0000000000000000000001'}]}};
  const builder = new (load(41332).t)();
  builder.locale = input.locale;
  builder.market = 'from_token';
  builder.accessToken = 'fixture-access-token';
  builder.globalRequestHeaders = [['App-Platform', 'OSX_ARM64'], ['Spotify-App-Version', '1.3.6.1921']];
  builder.transport = {request: async (url, options) => {
    requests.push({url, method: options.method, headers: options.headers, bodyBase64: '',
      authorize: options.authorize, includeCredentials: options.credentials === 'include', responseType: options.responseType});
    return response;
  }};
  builderContext.builder = builder;
  let tree = load(53150).z({uri: input.uri, displayText: 'Go to song radio', divider: 'before'});
  while (typeof tree.type === 'function') tree = tree.type(tree.props);
  const allowed = load(39732).p();
  if (!tree.props.disabled) await tree.props.onClick();
  const item = {input, allowed, disabled: tree.props.disabled, requests, navigations, events};
  if (requests.length) {
    const target = new URL(requests[0].url);
    const reference = getReference.cases.find(item => item.kind === 'lyrics' && item.locale === input.locale)
      ?? getReference.cases.find(item => item.kind === 'lyrics');
    item.application = requests[0];
    item.expected = {...reference.expected, ':authority': target.host, ':path': `${target.pathname}${target.search}`,
      'accept-language': input.locale};
    item.expectedPreflight = {...reference.expectedPreflight, ':authority': target.host, ':path': `${target.pathname}${target.search}`};
    item.response = response.body;
  }
  cases.push(item);
}
const report = {
  source: {application: 'Spotify macOS', version: '1.3.6.1921', bundlePath, bundleSha256: digest(source), sources},
  cases,
  browserGetReference: {path: 'reverse-engineering/fixtures/native-renderer-lyrics.json',
    sha256: digest(fs.readFileSync('reverse-engineering/fixtures/native-renderer-lyrics.json')),
    wireSource: getReference.wireSource},
  substitutions: [
    'Node WHATWG URL and URLSearchParams replace browser standard URL primitives. Original URI parser and its transpiler helper execute unchanged.',
    'React JSX/memo/hooks are inert tree/callback primitives; presentation, icons, localization, keyboard shortcuts and navigation are captured boundaries.',
    'Product-state lookup and online status are supplied inputs; the original personalized-recommendation gate executes unchanged.',
    'Original RequestBuilder and SpotifyTransportRequest execute unchanged with synthetic credentials and a recording transport returning synthetic playlists.',
    'Decoded browser GET/preflight fields and ordering reuse the independent renderer NetLog GET reference. Only the original-executed target and supplied application locale vary.',
  ],
  scope: 'Proves the original song-radio menu gate, exact application GET URL/headers/options, first-result selection and navigation without autoplay. Browser-managed fields inherit the existing renderer GET capture; this is not a new radio-specific wire capture. No live request, advertising, media playback, Chromium decompilation or TLS/QUIC/QPACK parity is claimed.',
};
fs.writeFileSync('reverse-engineering/fixtures/native-song-radio.json', `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify({source: report.source, cases: cases.map(item => ({name: item.input.name,
  allowed: item.allowed, disabled: item.disabled, requests: item.requests.length, navigations: item.navigations}))}));
