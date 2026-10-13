import { expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../apps/duskmoon_bundler/priv/ts/runtime/preload.ts', import.meta.url), 'utf8');
const code = new Bun.Transpiler({loader: 'ts'}).transformSync(source.replaceAll('import.meta.url', '"https://example.test/assets/entry.js"'));

function runtime() {
  const links: any[] = [];
  const events: any[] = [];
  const context = vm.createContext({URL, Set, Promise, JSON,
    CustomEvent: class { constructor(public type: string, public detail: any) {} },
    window: {dispatchEvent: (event: any) => events.push(event)},
    document: {querySelector: () => null, createElement: () => ({}), head: {appendChild: (link: any) => links.push(link)}}});
  vm.runInContext(code + ';globalThis.preload=__duskmoon_bundlerPreload;', context);
  return {preload: context.preload, links, events};
}

test('lazy imports share module preloads and await stylesheet loading', async () => {
  const {preload, links} = runtime();
  let loaded = false;
  const pending = preload(() => { loaded = true; return 'chunk'; }, ['shared.js', 'chunk.css']);
  expect(links.map(link => [link.rel, link.href])).toEqual([
    ['modulepreload', 'https://example.test/assets/shared.js'],
    ['stylesheet', 'https://example.test/assets/chunk.css']]);
  await Promise.resolve();
  expect(loaded).toBe(false);
  links[1].onload();
  expect(await pending).toBe('chunk');
  await preload(() => 'second', ['shared.js']);
  expect(links.length).toBe(2);
});

test('failed lazy imports propagate the error and report it to the consumer', async () => {
  const {preload, events} = runtime();
  const error = new Error('chunk unavailable');
  await expect(preload(() => Promise.reject(error), [])).rejects.toThrow('chunk unavailable');
  expect(events[0].type).toBe('duskmoon_bundler:preloadError');
  expect(events[0].detail.detail).toBe(error);
});
