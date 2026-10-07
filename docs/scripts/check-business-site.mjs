import assert from 'node:assert/strict';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import { runInNewContext } from 'node:vm';

const [directory, ...extraArguments] = process.argv.slice(2);
assert.ok(directory && extraArguments.length === 0, 'Usage: check-business-site.mjs <build-directory>');
const root = resolve(directory);
const html = (path) => readFileSync(resolve(root, path, 'index.html'), 'utf8');
const home = html('');
const publicRepositories = ['.github', 'agent-plugins', 'agent-skills', 'data-product-controller', 'dotnet-template', 'go-template', 'ksail', 'kyverno-policies', 'platform-template', 'platform-tenant-template', 'provider-upjet-unifi', 'world-at-ruin'];
const starSnapshot = JSON.parse(readFileSync(new URL('../src/data/github-stars.json', import.meta.url), 'utf8'));

assert.ok(home.includes('data-business-site'), 'Production build must publish the business homepage without an opt-in flag');

// Catch a visitor leaving the business site and losing its navigation, theme
// controls or inquiry route on a supporting page.
const navigation = (page, locale) => {
  const nav = page.match(/<nav[^>]*data-business-nav[^>]*>([\s\S]*?)<\/nav>/)?.[1];
  assert.ok(nav, 'Every business and supporting page must expose the shared business navigation');
  const prefix = locale === 'da' ? '/da' : '';
  for (const target of [`${prefix}/about/`, `${prefix}/projects/`, '/blog/']) {
    assert.ok(nav.includes(`href="${target}"`), `Visitors can reach ${target} from the shared navigation`);
  }
  assert.match(page, /<select[^>]*id="theme-select"/, 'Appearance controls remain available throughout the site');
  assert.equal((page.match(/<select\b/g) ?? []).length, 1, 'A supporting page must not expose a second, unsynchronized appearance picker');
  assert.ok(page.includes('data-business-footer'), 'Supporting pages keep the business identity and return route');
};
for (const locale of ['en', 'da']) {
  const prefix = locale === 'da' ? 'da/' : '';
  for (const section of ['about', 'projects']) {
    const page = html(`${prefix}${section}`);
    navigation(page, locale);
    assert.match(page, new RegExp(`<html[^>]+lang="${locale}"`), 'Business supporting pages have the correct language');
    assert.equal((page.match(/<h1\b/g) ?? []).length, 1, 'Supporting pages have one clear heading');
    const own = `/${prefix}${section}/`;
    const alternate = locale === 'da' ? `/${section}/` : `/da/${section}/`;
    assert.ok(page.includes(`rel="canonical" href="https://devantler.tech${own}"`), 'Supporting page canonical is self-referencing');
    assert.ok(page.includes(`href="${alternate}"`), 'Changing language stays on the same supporting page');
    if (section === 'about') {
      assert.match(page, /<img[^>]*alt="Nikolai Emil Damm"/, 'The business biography identifies its real founder');
      assert.ok(page.includes('href="/pdfs/nikolai-emil-damm-cv.pdf"'), 'The founder’s professional background remains available');
    } else {
      const shelf = page.match(/<section[^>]*aria-labelledby="open-title"[^>]*>([\s\S]*?)<\/section>/)?.[1];
      assert.ok(shelf, 'The public products shelf is reachable on the unified Projects page');
      const overflow = shelf.match(/<details[^>]*id="more-public-products"[^>]*>([\s\S]*?)<\/details>/);
      assert.ok(overflow, 'Products beyond the top six live in one disclosure below the shelf');
      assert.ok(!/\sopen(?:[\s=>])/.test(overflow[0].split('>')[0]), 'Additional public products are initially collapsed');
      const repositories = (markup) => [...markup.matchAll(/<article\b[^>]*data-public-product="([^"]+)"/g)].map((match) => match[1]);
      const featured = repositories(shelf.slice(0, shelf.indexOf(overflow[0])));
      assert.equal(featured.length, 6, 'Exactly six leading public products are visible');
      const allRepositories = repositories(shelf);
      assert.deepEqual([...allRepositories].sort(), publicRepositories, 'All current reusable products appear once, without tenants or legacy duplicates');
      const ranked = [...shelf.matchAll(/<article\b[^>]*data-public-product="([^"]+)"[^>]*data-stars="(\d+)"/g)].map(([, repository, stars]) => ({ repository, stars: Number(stars) }));
      assert.equal(ranked.length, publicRepositories.length, 'Every public product has a verified star count');
      for (const product of ranked) assert.equal(product.stars, starSnapshot.repositories[product.repository], 'Rendered star counts match the observed snapshot');
      for (let i = 1; i < ranked.length; i++) {
        const before = ranked[i - 1], after = ranked[i];
        assert.ok(before.stars > after.stars || (before.stars === after.stars && before.repository < after.repository), 'GitHub stars descend across both groups with stable repository-name ties');
      }
      assert.deepEqual(repositories(overflow[1]), allRepositories.slice(6), 'The rest sit immediately below the leading six, in the same order');
      assert.match(overflow[1], /data-stars="0"/, 'Zero-star products are included, not discarded as missing');
      assert.match(shelf, /<time[^>]*datetime="\d{4}-\d{2}-\d{2}"/, 'Star counts carry a visible observation date');
      assert.ok(shelf.includes(`datetime="${starSnapshot.observedAt}"`), 'The displayed star date matches the observation');
      assert.match(shelf, /world-at-ruin\/blob\/main\/LICENSE/, 'The game links to its distinct source-available terms');
      assert.ok(shelf.includes(locale === 'da' ? 'Kildekode tilgængelig' : 'Source-available'), 'The game is not presented as unrestricted open source');
      for (const repository of publicRepositories) assert.ok(shelf.includes(`href="https://github.com/devantler-tech/${repository}"`), `${repository} retains its real repository link`);
      assert.ok(page.includes('href="https://ksail.devantler.tech"'), 'Projects link to their real public product');
      for (const id of ['open-title', 'family-title', 'technical-projects', 'research']) {
        assert.ok(page.includes(`id="${id}"`), `The unified portfolio includes ${id}`);
      }
      assert.ok(!page.includes('href="/projects/active/"') && !page.includes('href="/projects/completed/"'), 'Projects stay on one canonical page');
      assert.ok(!page.includes('sidebar-pane'), 'Projects use the business layout, not a floating documentation sidebar');
      for (const product of ['Data Product Controller', 'World at Ruin', 'Reusable Workflows', 'Kyverno Policies']) {
        assert.ok(page.includes(product), `The full technical catalogue retains ${product}`);
      }
      assert.ok(page.includes('href="/pdfs/thesis.pdf"'), 'Earlier research remains reachable');
      assert.match(page, /<details[^>]*id="technical-projects"/, 'Long technical detail is available without overwhelming the opening');
      const illustration = page.match(/<img[^>]*data-project-art[^>]*>/)?.[0];
      assert.ok(illustration, 'The portfolio includes a locally hosted editorial illustration');
      const illustrationPath = illustration.match(/src="([^"]+)"/)?.[1];
      assert.ok(illustrationPath && existsSync(resolve(root, `.${illustrationPath}`)), 'Project artwork is emitted locally');
    }
  }
}
for (const [path, target] of [['projects/active', '/projects/#technical-projects'], ['projects/completed', '/projects/#research']]) {
  const page = html(path);
  assert.match(page, /http-equiv="refresh"/i, 'Legacy project URLs redirect on static hosting');
  assert.ok(page.includes(target), `Legacy projects resolve to ${target}`);
  // A fixed meta-refresh loses the fragment of an old heading permalink.
  // Exercise the emitted browser code, not just the source or fallback link.
  const redirect = page.match(/<script\b([^>]*\bdata-project-redirect[^>]*)>([\s\S]*?)<\/script>/);
  assert.ok(redirect, 'Legacy heading links use a fragment-preserving browser redirect');
  const dataset = {
    destination: redirect[1].match(/data-destination="([^"]+)"/)?.[1],
    fallback: redirect[1].match(/data-fallback="([^"]+)"/)?.[1],
  };
  for (const [hash, expected] of [
    ['', target],
    ['#-data-product-controller--', '/projects/#-data-product-controller--'],
    ['#-data-product-', '/projects/#-data-product-'],
    ['#%EF%B8%8F-ksail---', '/projects/#%EF%B8%8F-ksail---'],
    ['#//outside.example/path', '/projects/#//outside.example/path'],
  ]) {
    const destinations = [];
    runInNewContext(redirect[2], {
      document: { currentScript: { dataset } },
      location: { hash, replace: (url) => destinations.push(url) },
    });
    assert.deepEqual(destinations, [expected], `Legacy ${path} preserves ${hash || 'the section fallback'}`);
  }
}
for (const path of ['blog', 'templates', 'agentic-engineering']) {
  navigation(html(path), 'en');
}
for (const [locale, path, alternate] of [['en', '', '/da/'], ['da', 'da', '/']]) {
  const page = html(path);
  navigation(page, locale);
  assert.match(page, new RegExp(`<html[^>]+lang="${locale}"`));
  assert.ok(page.includes('data-business-site'), 'Production build must publish the business homepage');
  assert.equal((page.match(/<h1\b/g) ?? []).length, 1, 'One clear page heading');
  const canonical = `https://devantler.tech/${path ? `${path}/` : ''}`;
  assert.ok(page.includes(`rel="canonical" href="${canonical}"`), 'Self-referencing canonical URL');
  assert.ok(page.includes(`href="https://devantler.tech${alternate}"`), 'Alternate language metadata');
  assert.ok(page.includes(`href="${alternate}"`), 'Visible language switch');
  assert.match(page, /<select[^>]*id="theme-select"/, 'Visitors can choose an appearance');
  for (const [value, label] of locale === 'en' ? [['auto', 'System'], ['light', 'Light'], ['dark', 'Dark']] : [['auto', 'System'], ['light', 'Lys'], ['dark', 'Mørk']]) {
    assert.match(page, new RegExp(`<option[^>]*value="${value}"[^>]*>${label}</option>`), 'Localized theme options');
  }
  assert.match(page, /<label[^>]*for="theme-select"/, 'Theme selector has an accessible label');
  const art = page.match(/<img[^>]*data-hero-art[^>]*>/)?.[0];
  assert.ok(art, 'Hero includes the original decorative artwork');
  assert.match(art, /\salt(?:=""|(?=\s|>))/, 'Decorative artwork must not distract screen readers');
  const artPath = art.match(/src="([^"]+)"/)?.[1];
  assert.ok(artPath && existsSync(resolve(root, `.${artPath}`)), 'Hero artwork is emitted locally');
  const hero = page.match(/<section[^>]*aria-labelledby="hero-title"[^>]*>([\s\S]*?)<\/section>/)?.[1];
  assert.ok(hero, 'Visitors can identify the business introduction');
  const portrait = hero.match(/<img[^>]*alt="Nikolai Emil Damm"[^>]*>/)?.[0];
  assert.ok(portrait, 'The opening section identifies the developer with an accessible portrait');
  const portraitPath = portrait.match(/src="([^"]+)"/)?.[1];
  assert.ok(portraitPath && existsSync(resolve(root, `.${portraitPath}`)), 'The developer portrait is served locally');
  assert.match(portraitPath, /\/profile\.[^/]+\.webp$/, 'Use the existing public profile photograph, not the illustrated avatar');
  assert.ok(hero.includes(`href="${locale === 'da' ? '/da/about/' : '/about/'}"`), 'Visitors can follow the business biography in their selected language');
  assert.match(hero, /href="https:\/\/github\.com\/devantler"/, 'Visitors can inspect the developer’s verified public work');
  const socialPortrait = page.match(/<meta[^>]*property="og:image"[^>]*content="([^"]+)"/)?.[1];
  assert.ok(socialPortrait, 'Sharing identifies the person behind the business');
  assert.equal(new URL(socialPortrait).origin, 'https://devantler.tech', 'Sharing uses the locally hosted portrait');
  assert.ok(existsSync(resolve(root, `.${new URL(socialPortrait).pathname}`)), 'The sharing portrait is emitted, not a broken asset');
  assert.match(new URL(socialPortrait).pathname, /\/profile\.[^/]+\.webp$/, 'Sharing uses the same real photograph');
  const initializer = page.match(/<script[^>]*data-business-theme[^>]*>([\s\S]*?)<\/script>/);
  assert.ok(initializer && page.indexOf(initializer[0]) < page.indexOf('</head>'), 'Theme is initialized before the body paints');
  const documentElement = { dataset: {}, style: {} };
  runInNewContext(initializer[1], {
    document: { documentElement, readyState: 'loading', addEventListener() {} },
    window: {
      matchMedia: () => ({ matches: false, addEventListener() {} }),
      localStorage: { getItem: () => 'light' }, addEventListener() {},
    },
  });
  assert.equal(documentElement.dataset.theme, 'light', 'The emitted head script restores the saved preference');
  const stylesheets = [...page.matchAll(/<link[^>]*rel="stylesheet"[^>]*href="([^"]+)"/g)];
  assert.ok(stylesheets.length > 0, 'Business design must have an emitted stylesheet');
  for (const [, stylesheet] of stylesheets) {
    const css = readFileSync(resolve(root, `.${stylesheet}`), 'utf8');
    assert.ok(!css.includes('--sl-color-'), 'Documentation styles must not leak into the business entrypoint');
  }
  for (const id of ['services', 'work', 'products', 'process', 'contact']) {
    assert.ok(page.includes(`id="${id}"`), `Missing visitor section: ${id}`);
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
// Pin delivered covers, not just source frontmatter or a filename substring.
const editorialCovers = [
  ['building-ksail-from-shell-to-dotnet-to-go', 'code-craft'],
  ['autonomous-oss-with-github-agentic-workflows', 'workflows'],
  ['gitops-without-the-git-server-oci-registries-as-a-flux-source-with-ksail', 'cloud-fleet'],
  ['mcp-server-for-kubernetes-cluster-management', 'agent-dialogue'],
  ['creating-development-kubernetes-clusters-on-hetzner-with-ksail-and-talos', 'cloud-fleet'],
  ['local-kubernetes-development-with-ksail-and-kind', 'kubernetes-workshop'],
  ['storing-secrets-in-zshrc-with-macos-keychain', 'developer-workbench'],
  ['ai-powered-github-issues-with-copilot-and-claude-opus', 'workflows'],
  ['macos-as-a-developer-machine', 'developer-workbench'],
  ['why-i-chose-the-polyform-shield-license-for-ksail', 'software-ownership'],
  ['building-an-ai-assistant-for-kubernetes-with-github-copilot-sdk', 'agent-dialogue'],
  ['local-kubernetes-development-with-ksail-and-talos', 'kubernetes-workshop'],
  ['how-my-agentic-engineer-turns-problems-into-proved-working-solutions', 'workflows'],
  ['local-kubernetes-development-with-ksail-and-k3d', 'kubernetes-workshop'],
];
for (const [slug, subject] of editorialCovers) {
  const page = html(`blog/${slug}`);
  const cover = [...page.matchAll(/<img\b[^>]*>/g)].map((match) => match[0]).find((tag) => /class="[^"]*sl-blog-cover-image/.test(tag));
  assert.ok(cover, `Journal post ${slug} has a delivered cover`);
  assert.match(cover, /alt="Illustration of /, 'Generated covers are described as illustrations, not evidence');
  assert.match(cover, /width="1440" height="810"/, 'Covers reserve a consistent landscape frame');
  const asset = cover.match(/src="([^"]+)"/)?.[1];
  assert.ok(asset?.startsWith(`/_astro/${subject}.`) && asset.endsWith('.webp'), `${slug} uses its intended subject illustration`);
  const path = resolve(root, `.${asset}`);
  assert.ok(existsSync(path), `Cover for ${slug} is served locally`);
  assert.ok(statSync(path).size < 220_000, 'Editorial covers stay below 220 kB at full size');
}
console.log('Published business visitor journey and editorial artwork verified.');
