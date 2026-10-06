import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

const [directory, state] = process.argv.slice(2);
assert.ok(directory && ['true', 'false'].includes(state), 'Usage: check-business-site.mjs <build-directory> <true|false>');
const root = resolve(directory);
const html = (path) => readFileSync(resolve(root, path, 'index.html'), 'utf8');
const home = html('');

if (state === 'false') {
  assert.ok(!home.includes('data-business-site'), 'Disabled feature must retain the personal homepage');
  assert.match(home, /Featured Projects/);
  assert.match(home, /Nikolai Emil Damm/);
  assert.ok(!existsSync(resolve(root, 'da/index.html')), 'Disabled build must omit the unreleased Danish route');
} else {
  for (const [locale, path, alternate] of [['en', '', '/da/'], ['da', 'da', '/']]) {
    const page = html(path);
    assert.match(page, new RegExp(`<html[^>]+lang="${locale}"`));
    assert.ok(page.includes('data-business-site'), 'Enabled build must publish the business homepage');
    assert.equal((page.match(/<h1\b/g) ?? []).length, 1, 'One clear page heading');
    const canonical = `https://devantler.tech/${path ? `${path}/` : ''}`;
    assert.ok(page.includes(`rel="canonical" href="${canonical}"`), 'Self-referencing canonical URL');
    assert.ok(page.includes(`href="https://devantler.tech${alternate}"`), 'Alternate language metadata');
    assert.ok(page.includes(`href="${alternate}"`), 'Visible language switch');
    const stylesheets = [...page.matchAll(/<link[^>]*rel="stylesheet"[^>]*href="([^"]+)"/g)];
    assert.ok(stylesheets.length > 0, 'Business design must have an emitted stylesheet');
    for (const [, stylesheet] of stylesheets) {
      const css = readFileSync(resolve(root, `.${stylesheet}`), 'utf8');
      assert.ok(!css.includes('--sl-color-'), 'Documentation styles must not leak into the business entrypoint');
    }
    for (const id of ['services', 'work', 'products', 'process', 'contact']) {
      assert.ok(page.includes(`id="${id}"`), `Missing visitor section: ${id}`);
      assert.ok(page.includes(`href="#${id}"`), `Missing navigation to ${id}`);
    }
    for (const [service, setup, monthly] of [['website', 2995, 99], ['app', 7995, 299], ['service', 4995, 199]]) {
      assert.match(page, new RegExp(`data-offer="${service}"[^>]*data-setup="${setup}"[^>]*data-monthly="${monthly}"`));
      assert.ok(page.includes(new Intl.NumberFormat(locale === 'da' ? 'da-DK' : 'en-DK').format(setup)), 'Starting price must be visible');
    }
    assert.ok(page.includes('href="https://www.linkedin.com/in/nikolai-emil-damm-14a786150/"'), 'Inquiry route must be the verified public profile');
    assert.ok(!page.includes('<form'), 'Do not present a contact form without delivery');
    for (const href of page.matchAll(/href="(\/[^"?#]*)(?:[?#][^"]*)?"/g)) {
      const target = href[1];
      if (/\.[a-z0-9]+$/i.test(target)) assert.ok(existsSync(resolve(root, `.${target}`)), `Missing asset: ${target}`);
      else assert.ok(existsSync(resolve(root, `.${target}`, 'index.html')), `Broken internal link: ${target}`);
    }
    for (const anchor of page.matchAll(/href="#([^"]+)"/g)) {
      assert.ok(page.includes(`id="${anchor[1]}"`), `Broken section link: ${anchor[1]}`);
    }
  }
}
console.log(`Business visitor journey verified (enabled=${state}).`);
