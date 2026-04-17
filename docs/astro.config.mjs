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
        {
          tag: "script",
          attrs: {
            src: "https://www.googletagmanager.com/gtag/js?id=G-MK59Q89KYW",
            async: true,
          },
        },
        {
          tag: "script",
          content: `window.dataLayer = window.dataLayer || [];
function gtag(){dataLayer.push(arguments);}
gtag('js', new Date());
gtag('config', 'G-MK59Q89KYW');`,
        },
        {
          tag: "script",
          content: `document.addEventListener('DOMContentLoaded',()=>{document.addEventListener('click',e=>{const a=e.target.closest('a');if(a)return;const article=e.target.closest('main article, .blog-post-list article');if(!article)return;const link=article.querySelector('h2 a');if(link){window.location.href=link.href;}});});`,
        },
      ],
      sidebar: [
        {
          label: "About Me",
          link: "/about/",
        },
        {
          label: "Projects",
          autogenerate: { directory: "projects" },
        },
        {
          label: "Templates",
          autogenerate: { directory: "templates" },
        },
      ],
      lastUpdated: true,
      pagination: true,
      tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
    }),
  ],
});
