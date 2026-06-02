import starlight from "@astrojs/starlight";
import mermaid from "astro-mermaid";
import { defineConfig } from "astro/config";
import starlightBlog from "starlight-blog";
import starlightGithubAlerts from "starlight-github-alerts";
import starlightLinksValidator from "starlight-links-validator";

export default defineConfig({
  site: "https://devantler.tech",
  integrations: [
    mermaid(),
    starlight({
      title: "Nikolai Emil | Devantler",
      description:
        "Personal site of Nikolai Emil Damm — software engineer, open-source advocate, and Kubernetes enthusiast.",
      defaultLocale: "en",
      logo: {
        src: "./src/assets/author.png",
        replacesTitle: false,
      },
      favicon: "/favicon.png",
      social: [
        {
          icon: "linkedin",
          label: "LinkedIn",
          href: "https://www.linkedin.com/in/nikolai-emil-damm-14a786150/",
        },
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/devantler",
        },
        {
          icon: "rss",
          label: "RSS",
          href: "/blog/rss.xml",
        },
      ],
      editLink: {
        baseUrl:
          "https://github.com/devantler-tech/monorepo/edit/main/docs/",
      },
      customCss: ["./src/styles/custom.css"],
      plugins: [
        starlightBlog({
          title: "Blog",
          authors: {
            devantler: {
              name: "Nikolai Emil Damm",
              title: "Developer Experience Engineer",
              picture: "/author.png",
              url: "https://github.com/devantler",
            },
          },
        }),
        starlightGithubAlerts(),
        starlightLinksValidator({
          errorOnRelativeLinks: false,
          exclude: ["/blog/**", "/blog/"],
        }),
      ],
      head: [
        {
          tag: "meta",
          attrs: { property: "og:image", content: "https://devantler.tech/author.png" },
        },
        {
          tag: "meta",
          attrs: { property: "og:type", content: "website" },
        },
        {
          tag: "meta",
          attrs: { name: "twitter:card", content: "summary_large_image" },
        },
        {
          tag: "meta",
          attrs: { name: "twitter:image", content: "https://devantler.tech/author.png" },
        },
        {
          tag: "meta",
          attrs: { name: "author", content: "Nikolai Emil Damm" },
        },
        // Umami privacy-first web analytics (self-hosted on the platform). The
        // website-id is fixed and managed declaratively — the matching Umami
        // "website" is provisioned from Git on the platform (no UI click-ops).
        // data-domains restricts the tracker to the trusted host so the public
        // website-id can't be used to send events from a spoofed site.
        {
          tag: "script",
          attrs: {
            src: "https://analytics.platform.devantler.tech/script.js",
            "data-website-id": "2f8d150e-c6f0-4a90-ab77-431c9ef9dc59",
            "data-domains": "devantler.tech",
            defer: true,
          },
        },
        {
          tag: "script",
          content: `document.addEventListener('DOMContentLoaded',()=>{const sel='main article, .blog-post-list article';function navigate(article){const link=article.querySelector('h2 a');if(link)window.location.href=link.href;}document.addEventListener('click',e=>{if(e.target.closest('a'))return;const article=e.target.closest(sel);if(article)navigate(article);});document.querySelectorAll(sel).forEach(el=>{const link=el.querySelector('h2 a');if(!link)return;el.setAttribute('tabindex','0');el.setAttribute('role','link');el.setAttribute('aria-label',link.textContent.trim());el.addEventListener('keydown',e=>{if(e.target!==el)return;if(e.key==='Enter'||e.code==='Space'||e.key===' '||e.key==='Spacebar'){e.preventDefault();navigate(el);}});});});`,
        },
      ],
      sidebar: [
        {
          label: "About Me",
          link: "/about/",
        },
        {
          label: "Projects",
          items: [{ autogenerate: { directory: "projects" } }],
        },
        {
          label: "Templates",
          items: [{ autogenerate: { directory: "templates" } }],
        },
      ],
      lastUpdated: true,
      pagination: true,
      tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
    }),
  ],
});
