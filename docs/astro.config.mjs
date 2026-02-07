import starlight from "@astrojs/starlight";
import mermaid from "astro-mermaid";
import { defineConfig } from "astro/config";
import starlightBlog from "starlight-blog";
import starlightGithubAlerts from "starlight-github-alerts";

export default defineConfig({
  site: "https://devantler.tech",
  integrations: [
    mermaid(),
    starlight({
      title: "Nikolai Emil | Devantler",
      description:
        "Personal site of Nikolai Emil Damm — software engineer, open-source advocate, and Kubernetes enthusiast.",
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
      ],
      head: [
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
