import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';

const archivePath = '/Applications/Spotify.app/Contents/Resources/Apps/xpui.spa';
const member = '387.js';
const chunk = execFileSync('/usr/bin/unzip', ['-p', archivePath, member], {maxBuffer: 1024 * 1024});
const source = chunk.toString('utf8');
const self = {rspackChunk: []};
vm.runInNewContext(source, {self}, {timeout: 5000});
const factories = new Map(self.rspackChunk.flatMap(chunk => Object.entries(chunk[1])));
const selectorBundlePath = '.local/native-scripts/59a1e2bad44f35bcf8b21a86fe2e95dc216e0614e2d65cbd1a8ad75c1d8ea79f.js';
const selectorBundle = fs.readFileSync(selectorBundlePath, 'utf8');
const headers = [...selectorBundle.matchAll(/(?:^|,)(\d+)\([a-z,]*\)\{/g)];
const selectorIndex = headers.findIndex(header => header[1] === '50242');
const selectorStart = headers[selectorIndex].index + 1;
const selectorBody = selectorBundle.slice(selectorStart, headers[selectorIndex + 1].index);
factories.set('50242', vm.runInNewContext(`({${selectorBody}})[50242]`));
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const cache = new Map();
let state = false;
const react = {
  memo: component => component,
  useMemo: callback => callback(),
  useCallback: callback => callback,
  useState: () => [state, value => { state = value; }],
};
const jsx = (type, props) => ({type, props});
const substitutions = new Map([
  [23955, {jsx, jsxs: jsx}], [62515, react], [28625, () => ''],
  [44115, {H: 'CloseButton'}], [24577, {H: 'CloseButton'}], [53745, {NC: () => false}],
  [86592, {Ru: {get: key => key}}], [52018, {A: 'Modal'}],
  [61276, {F: 'AdvancedImage'}], [15364, {c22: 'tilt'}], [11120, {_: 'Image'}],
]);
function load(id) {
  if (substitutions.has(id)) return substitutions.get(id);
  if (cache.has(id)) return cache.get(id);
  const module = {exports: {}};
  cache.set(id, module.exports);
  const factory = factories.get(String(id));
  if (!factory) throw new Error(`Missing original module ${id}`);
  factory(module, module.exports, load);
  return module.exports;
}
load.d = (exports, getters, values = {}) => {
  for (const [name, get] of Object.entries(getters)) Object.defineProperty(exports, name, {get, enumerable: true});
  for (const [name, value] of Object.entries(values)) Object.defineProperty(exports, name, {value, enumerable: true});
};
load.n = value => () => value;

const cover = load(23424).K;
const image = (name, width, height) => ({url: `https://fixture.invalid/${name}`, width, height});
const inputs = [
  {name: 'empty', images: []},
  {name: 'album', images: [image('small', 64, 64), image('medium', 300, 300), image('large', 640, 640)]},
  {name: 'descending', images: [image('large', 640, 640), image('small', 64, 64)]},
  {name: 'landscape', images: [image('small', 320, 180), image('header', 2660, 1140)]},
  {name: 'portrait', images: [image('small', 160, 200), image('portrait', 640, 800)]},
  {name: 'unknown-size', images: [{url: 'https://fixture.invalid/unknown'}]},
  {name: 'equal-area', images: [image('first', 800, 400), image('second', 400, 800)]},
  {name: 'width-only', images: [{url: 'https://fixture.invalid/small', width: 80}, {url: 'https://fixture.invalid/large', width: 640}]},
];
const executions = inputs.map(input => {
  const selected = load(50242).g(input.images, {desiredSize: 10000});
  let closeCalls = 0;
  const close = () => { closeCalls++; };
  const tree = cover({images: input.images, title: 'Fixture artwork', isOpen: true, onClose: close});
  if (tree) tree.props.children.props.children[1].props.onClick();
  return {input, selected: selected ?? null, modal: tree == null ? null : {
    type: tree.type, isOpen: tree.props.isOpen,
    image: tree.props.children.props.children[0],
    style: tree.props.children.props.style,
    closeLabel: tree.props.children.props.children[1].props.children,
    dismissAndButtonShareClose: tree.props.onRequestClose === close &&
      tree.props.children.props.children[1].props.onClick === close,
    closeCalls,
  }};
});
const hook = load(27741).W;
const states = [hook().isOpen];
hook().openModal(); states.push(hook().isOpen);
hook().closeModal(); states.push(hook().isOpen);
const report = {
  source: {application: 'Spotify macOS 1.3.9.2055', archivePath, member,
    archiveSha256: digest(fs.readFileSync(archivePath)), memberSha256: digest(chunk),
    modules: [23424, 27741].map(id => ({id, sha256: digest(factories.get(String(id)).toString())})),
    selector: {application: 'Spotify macOS 1.3.6.1921', bundlePath: selectorBundlePath,
      bundleSha256: digest(selectorBundle), module: 50242, sha256: digest(selectorBody)}},
  executions, openStates: states,
  substitutions: [
    'React JSX, memo and hooks are inert tree/state primitives; no DOM, Chromium or browser runs.',
    'The original shared image selector executes unchanged from the earlier captured renderer. The installed modal still calls module50242 with desiredSize10000.',
    'Image, modal and button components are inert element identifiers; the optional tilt flag returns false and localization returns its key.',
    'All input URLs are synthetic fixture.invalid values. No image bytes or network requests are produced.',
  ],
  scope: 'Executes the unchanged installed cover-modal factory, its open/close hook, and the original captured nearest-area selector. Proves selection, aspect-ratio styling, close binding and local state. Does not execute installed image transport, DOM dismissal, artist feature-flag assignment, or native playback.',
};
fs.writeFileSync('.local/artwork-original-execution.json', `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify({source: report.source, selected: executions.map(({input, selected}) => ({name: input.name, selected})), openStates: states}));
