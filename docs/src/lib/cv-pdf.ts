import PDFDocument from "pdfkit";
import interRegular from "@expo-google-fonts/inter/400Regular/Inter_400Regular.ttf?inline";
import interMedium from "@expo-google-fonts/inter/500Medium/Inter_500Medium.ttf?inline";
import interSemibold from "@expo-google-fonts/inter/600SemiBold/Inter_600SemiBold.ttf?inline";
import interBold from "@expo-google-fonts/inter/700Bold/Inter_700Bold.ttf?inline";
import monoRegular from "@expo-google-fonts/roboto-mono/400Regular/RobotoMono_400Regular.ttf?inline";
import monoMedium from "@expo-google-fonts/roboto-mono/500Medium/RobotoMono_500Medium.ttf?inline";
import { cv, type Entry, type Role, type SkillGroup } from "../data/cv";

// A4 in PostScript points.
const PAGE = { width: 595.28, height: 841.89 };

// Two-column layout: a dark sidebar in the site's dark theme, a white main column.
const SIDEBAR = { width: 178, pad: 20 };
const MAIN = { x: SIDEBAR.width + 28, right: 30, top: 40, bottom: 38 };
const SIDEBAR_FOOTER_TOP = PAGE.height - 60;
const MAIN_WIDTH = PAGE.width - MAIN.x - MAIN.right;
const TIMELINE_INDENT = 16;

// Palette mirrors src/styles/custom.css: neon green on the dark surface, forest green on white.
const COLOR = {
  sidebarBg: "#111219",
  sidebarText: "#c1c3c8",
  sidebarMuted: "#888c96",
  sidebarRule: "#2a2c36",
  accent: "#39ff14",
  accentOnWhite: "#15803d",
  accentRail: "#cfe9d6",
  text: "#17181c",
  muted: "#555962",
  rule: "#e4e7ee",
  white: "#ffffff",
};

// Fonts are imported as data URIs so the renderer has no filesystem layout to depend on.
const dataUriToBuffer = (uri: string) => Buffer.from(uri.slice(uri.indexOf(",") + 1), "base64");

const FONT = {
  sans: "Inter",
  sansMedium: "Inter-Medium",
  sansSemibold: "Inter-SemiBold",
  sansBold: "Inter-Bold",
  mono: "RobotoMono",
  monoMedium: "RobotoMono-Medium",
};

const FONT_DATA: Record<string, string> = {
  [FONT.sans]: interRegular,
  [FONT.sansMedium]: interMedium,
  [FONT.sansSemibold]: interSemibold,
  [FONT.sansBold]: interBold,
  [FONT.mono]: monoRegular,
  [FONT.monoMedium]: monoMedium,
};

export interface CvPdfOptions {
  /** Portrait photo as a path, Buffer, or data URI (JPEG or PNG). */
  photo: string | Buffer;
  /** Shown as "Updated <month> <year>" in the sidebar footer. */
  updatedAt: Date;
}

interface TextStyle {
  font: string;
  size: number;
  color: string;
  lineGap?: number;
  characterSpacing?: number;
}

const STYLE = {
  sectionTitle: { font: FONT.sansBold, size: 9.5, color: COLOR.accentOnWhite, characterSpacing: 1.6 },
  entryTitle: { font: FONT.sansSemibold, size: 10.2, color: COLOR.text },
  entryMeta: { font: FONT.sansMedium, size: 8.3, color: COLOR.muted },
  period: { font: FONT.monoMedium, size: 7.3, color: COLOR.accentOnWhite },
  body: { font: FONT.sans, size: 8.8, color: COLOR.text, lineGap: 1.8 },
  link: { font: FONT.mono, size: 7.3, color: COLOR.accentOnWhite },
  sideLabel: { font: FONT.sansBold, size: 6.6, color: COLOR.accent, characterSpacing: 1.3 },
  sideValue: { font: FONT.sans, size: 7.8, color: COLOR.sidebarText, lineGap: 1.6 },
  sideMuted: { font: FONT.sans, size: 7.2, color: COLOR.sidebarMuted, lineGap: 1.4 },
} satisfies Record<string, TextStyle>;

const displayUrl = (url: string) => url.replace(/^https?:\/\//, "").replace(/\/$/, "");

interface EntryLayout {
  title: string;
  period?: string;
  meta?: string;
  metaStyle?: TextStyle;
  metaUrl?: string;
  summary?: string;
  bullets?: string[];
  url?: string;
}

class CvRenderer {
  private readonly doc: PDFKit.PDFDocument;
  private y = MAIN.top;
  private pageIndex = 0;
  private timeline: number[] = [];

  constructor(private readonly options: CvPdfOptions) {
    this.doc = new PDFDocument({
      size: "A4",
      margin: 0,
      bufferPages: true,
      pdfVersion: "1.7",
      lang: "en",
      displayTitle: true,
      info: {
        Title: `${cv.name} — CV`,
        Author: cv.name,
        Subject: `${cv.title} — curriculum vitae`,
        Keywords: "CV, resume, developer experience, platform engineering, Kubernetes, GitOps",
        Creator: "devantler.tech",
        CreationDate: options.updatedAt,
        ModDate: options.updatedAt,
      },
    });
    for (const [name, data] of Object.entries(FONT_DATA)) this.doc.registerFont(name, dataUriToBuffer(data));
  }

  render(): Promise<Buffer> {
    const chunks: Buffer[] = [];
    const done = new Promise<Buffer>((resolve, reject) => {
      this.doc.on("data", (chunk: Buffer) => chunks.push(chunk));
      this.doc.on("end", () => resolve(Buffer.concat(chunks)));
      this.doc.on("error", reject);
    });

    this.drawSidebar();
    this.drawMain();
    this.drawPageNumbers();
    this.doc.end();
    return done;
  }

  // ─── Main column ───

  private drawMain() {
    this.paragraph(cv.profile, MAIN.x, MAIN_WIDTH, STYLE.body);
    this.y += 8;

    this.section("Experience");
    this.roles(cv.experience);

    this.section("Earlier Experience");
    this.roles(cv.earlierExperience);

    this.section("Education");
    this.entries(cv.education);

    this.section("Talks");
    this.entries(cv.talks);

    this.section("Open Source");
    this.entries(cv.openSource);
  }

  private section(title: string) {
    // Keep the heading with whatever follows it: never strand it at the bottom of a page.
    this.ensure(70);
    this.y += 2;
    this.text(title.toUpperCase(), MAIN.x, this.y, MAIN_WIDTH, STYLE.sectionTitle);
    this.y += 13;
    this.doc.moveTo(MAIN.x, this.y).lineTo(MAIN.x + MAIN_WIDTH, this.y).lineWidth(0.8).stroke(COLOR.rule);
    this.doc.moveTo(MAIN.x, this.y).lineTo(MAIN.x + 34, this.y).lineWidth(2).stroke(COLOR.accentOnWhite);
    this.y += 12;
  }

  private roles(roles: Role[]) {
    for (const role of roles) {
      const meta = [role.organisation, role.location].join(", ") + (role.engagement ? ` · ${role.engagement}` : "");
      this.entry({ title: role.title, meta, period: role.period, summary: role.summary, bullets: role.highlights });
    }
    this.flushTimeline();
  }

  private entries(items: Entry[]) {
    for (const item of items) {
      // Without a subtitle the link takes its place, so a project reads as "name → where to find it".
      const linkAsMeta = !item.subtitle && item.url;
      this.entry({
        title: item.title,
        period: item.period,
        meta: linkAsMeta ? displayUrl(item.url!) : item.subtitle,
        metaStyle: linkAsMeta ? STYLE.link : STYLE.entryMeta,
        metaUrl: linkAsMeta ? item.url : undefined,
        summary: item.summary,
        url: linkAsMeta ? undefined : item.url,
      });
    }
    this.flushTimeline();
  }

  private entry(item: EntryLayout) {
    const x = MAIN.x + TIMELINE_INDENT;
    const width = MAIN_WIDTH - TIMELINE_INDENT;
    const periodWidth = item.period ? this.width(item.period, STYLE.period) + 14 : 0;
    const titleWidth = width - periodWidth;
    const metaStyle = item.metaStyle ?? STYLE.entryMeta;
    const linkText = item.url ? displayUrl(item.url) : undefined;

    let height = this.height(item.title, titleWidth, STYLE.entryTitle);
    if (item.meta) height += 2 + this.height(item.meta, width, metaStyle);
    if (item.summary) height += 5 + this.height(item.summary, width, STYLE.body);
    for (const bullet of item.bullets ?? []) height += 3 + this.height(bullet, width - 11, STYLE.body);
    if (linkText) height += 4 + this.height(linkText, width, STYLE.link);
    height += 8;
    this.ensure(height);

    this.timeline.push(this.y + STYLE.entryTitle.size * 0.55);
    if (item.period) {
      this.text(item.period, x + titleWidth + 14, this.y + 2, periodWidth - 14, STYLE.period, {
        align: "right",
        lineBreak: false,
      });
    }
    this.y += this.text(item.title, x, this.y, titleWidth, STYLE.entryTitle);
    if (item.meta) {
      this.y += 2 + this.text(item.meta, x, this.y + 2, width, metaStyle, item.metaUrl ? { link: item.metaUrl } : {});
    }
    if (item.summary) this.y += 5 + this.text(item.summary, x, this.y + 5, width, STYLE.body);
    for (const bullet of item.bullets ?? []) {
      this.y += 3;
      this.doc.circle(x + 3, this.y + STYLE.body.size * 0.55, 1.4).fill(COLOR.accentOnWhite);
      this.y += this.text(bullet, x + 11, this.y, width - 11, STYLE.body);
    }
    if (linkText) {
      this.y += 4;
      this.y += this.text(linkText, x, this.y, width, STYLE.link, { link: item.url });
    }
    this.y += 8;
  }

  /** Draws the vertical rail through the entry markers collected since the last flush. */
  private flushTimeline() {
    if (this.timeline.length === 0) return;
    const x = MAIN.x + 4;
    const first = this.timeline[0]!;
    const last = this.timeline[this.timeline.length - 1]!;
    if (this.timeline.length > 1) {
      this.doc.moveTo(x, first).lineTo(x, last).lineWidth(1.2).stroke(COLOR.accentRail);
    }
    for (const y of this.timeline) {
      this.doc.circle(x, y, 2.6).fillAndStroke(COLOR.accentOnWhite, COLOR.white);
    }
    this.timeline = [];
  }

  private paragraph(content: string, x: number, width: number, style: TextStyle) {
    this.ensure(this.height(content, width, style));
    this.y += this.text(content, x, this.y, width, style);
  }

  private ensure(height: number) {
    if (this.y + height <= PAGE.height - MAIN.bottom) return;
    this.flushTimeline();
    this.doc.addPage();
    this.pageIndex += 1;
    this.y = MAIN.top;
    this.drawSidebar();
  }

  // ─── Sidebar ───

  private drawSidebar() {
    const { doc } = this;
    doc.rect(0, 0, SIDEBAR.width, PAGE.height).fill(COLOR.sidebarBg);
    doc.rect(0, 0, 3, PAGE.height).fill(COLOR.accent);

    const x = SIDEBAR.pad;
    const width = SIDEBAR.width - SIDEBAR.pad * 2;
    let y = this.pageIndex === 0 ? this.sidebarHero(x, width) : this.sidebarCompactHero(x, width);

    const sections: Array<[string, (y: number) => number]> =
      this.pageIndex === 0
        ? [
            ["Contact", (y) => this.sideContact(x, width, y)],
            ["Technical Skills", (y) => this.sideSkills(cv.technicalSkills, x, width, y)],
            ["Languages", (y) => this.sideValue(cv.languages, x, width, y)],
          ]
        : this.pageIndex === 1
          ? [
              ["Personal Skills", (y) => this.sideSkills(cv.personalSkills, x, width, y)],
              ["Certifications & Badges", (y) => this.sideList(cv.certifications, x, width, y)],
              ["Courses", (y) => this.sideList(cv.courses, x, width, y)],
              ["Community", (y) => this.sideList(cv.community, x, width, y)],
              ["Interests", (y) => this.sideValue(cv.interests, x, width, y)],
            ]
          : [];
    for (const [title, body] of sections) y = this.sideSection(title, x, width, y, body);
    if (y > SIDEBAR_FOOTER_TOP) {
      throw new Error(
        `CV sidebar on page ${this.pageIndex + 1} overflows into its footer by ${Math.ceil(y - SIDEBAR_FOOTER_TOP)}pt: shorten a sidebar entry in src/data/cv.ts or move a section to another page in src/lib/cv-pdf.ts.`,
      );
    }

    this.sidebarFooter(x, width);
  }

  private sidebarHero(x: number, width: number): number {
    const { doc } = this;
    const radius = 46;
    const cx = SIDEBAR.width / 2;
    const cy = MAIN.top + radius;
    doc.save();
    doc.circle(cx, cy, radius).clip();
    doc.image(this.options.photo, cx - radius, cy - radius, {
      width: radius * 2,
      height: radius * 2,
      cover: [radius * 2, radius * 2],
      align: "center",
      valign: "center",
    });
    doc.restore();
    doc.circle(cx, cy, radius + 1).lineWidth(2).stroke(COLOR.accent);

    let y = cy + radius + 18;
    y += this.text(cv.name, x, y, width, { font: FONT.sansBold, size: 14.5, color: COLOR.white, lineGap: 1 }, { align: "center" });
    y += 6;
    y += this.text(cv.title.toUpperCase(), x, y, width, { ...STYLE.sideLabel, size: 7 }, { align: "center" });
    return this.sideDivider(y + 14);
  }

  private sidebarCompactHero(x: number, width: number): number {
    let y = MAIN.top;
    y += this.text(cv.name, x, y, width, { font: FONT.sansBold, size: 12.5, color: COLOR.white });
    y += 4;
    y += this.text(cv.title.toUpperCase(), x, y, width, { ...STYLE.sideLabel, size: 6.4 });
    return this.sideDivider(y + 12);
  }

  private sideDivider(y: number): number {
    this.doc.moveTo(SIDEBAR.pad, y).lineTo(SIDEBAR.width - SIDEBAR.pad, y).lineWidth(0.6).stroke(COLOR.sidebarRule);
    return y + 16;
  }

  private sideSection(title: string, x: number, width: number, y: number, body: (y: number) => number): number {
    this.text(title.toUpperCase(), x, y, width, STYLE.sideLabel);
    this.doc.moveTo(x, y + 12).lineTo(x + 18, y + 12).lineWidth(1.2).stroke(COLOR.accent);
    return body(y + 20) + 16;
  }

  private sideContact(x: number, width: number, y: number): number {
    const rows: Array<{ label: string; value: string; url?: string }> = [
      { label: "Website", value: cv.website.label, url: cv.website.url },
      { label: "GitHub", value: cv.github.label, url: cv.github.url },
      { label: "LinkedIn", value: cv.linkedin.label, url: cv.linkedin.url },
      { label: "Location", value: cv.location },
    ];
    for (const row of rows) {
      y += this.text(row.label, x, y, width, STYLE.sideMuted);
      y += 1 + this.text(row.value, x, y + 1, width, STYLE.sideValue, row.url ? { link: row.url } : {});
      y += 6;
    }
    return y - 6;
  }

  private sideSkills(groups: SkillGroup[], x: number, width: number, y: number): number {
    for (const group of groups) {
      y += this.text(group.label, x, y, width, { ...STYLE.sideMuted, font: FONT.sansSemibold, color: COLOR.white });
      y += 1 + this.text(group.value, x, y + 1, width, STYLE.sideValue);
      y += 7;
    }
    return y - 7;
  }

  private sideList(items: Entry[], x: number, width: number, y: number): number {
    for (const item of items) {
      y += this.text(item.title, x, y, width, { ...STYLE.sideValue, font: FONT.sansSemibold, color: COLOR.white });
      if (item.subtitle) y += 1 + this.text(item.subtitle, x, y + 1, width, STYLE.sideMuted);
      if (item.summary) y += 2 + this.text(item.summary, x, y + 2, width, STYLE.sideValue);
      y += 6;
    }
    return y - 6;
  }

  private sideValue(value: string, x: number, width: number, y: number): number {
    return y + this.text(value, x, y, width, STYLE.sideValue);
  }

  private sidebarFooter(x: number, width: number) {
    const updated = this.options.updatedAt.toLocaleDateString("en-GB", { month: "long", year: "numeric" });
    const y = PAGE.height - 40;
    this.doc.moveTo(x, y - 12).lineTo(x + width, y - 12).lineWidth(0.6).stroke(COLOR.sidebarRule);
    this.text(cv.website.label, x, y, width, { ...STYLE.link, color: COLOR.accent }, { link: cv.website.url });
    this.text(`Updated ${updated}`, x, y + 12, width, STYLE.sideMuted);
  }

  private drawPageNumbers() {
    const { doc } = this;
    const range = doc.bufferedPageRange();
    for (let i = 0; i < range.count; i++) {
      doc.switchToPage(range.start + i);
      this.text(`${i + 1} / ${range.count}`, MAIN.x, PAGE.height - 30, MAIN_WIDTH, { ...STYLE.link, color: COLOR.muted }, {
        align: "right",
      });
    }
  }

  // ─── Text primitives ───

  private apply(style: TextStyle) {
    this.doc.font(style.font).fontSize(style.size).fillColor(style.color);
  }

  private textOptions(style: TextStyle, width: number, extra: PDFKit.Mixins.TextOptions = {}): PDFKit.Mixins.TextOptions {
    return { width, lineGap: style.lineGap ?? 0, characterSpacing: style.characterSpacing ?? 0, ...extra };
  }

  /** Draws wrapped text at an absolute position and returns the height it occupied. */
  private text(content: string, x: number, y: number, width: number, style: TextStyle, extra: PDFKit.Mixins.TextOptions = {}): number {
    this.apply(style);
    const options = this.textOptions(style, width, extra);
    this.doc.text(content, x, y, options);
    return this.doc.heightOfString(content, options);
  }

  private height(content: string, width: number, style: TextStyle): number {
    this.apply(style);
    return this.doc.heightOfString(content, this.textOptions(style, width));
  }

  private width(content: string, style: TextStyle): number {
    this.apply(style);
    return this.doc.widthOfString(content, { characterSpacing: style.characterSpacing ?? 0 });
  }
}

export function renderCvPdf(options: CvPdfOptions): Promise<Buffer> {
  return new CvRenderer(options).render();
}
