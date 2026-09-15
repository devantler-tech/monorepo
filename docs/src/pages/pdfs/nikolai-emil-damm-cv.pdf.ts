import type { APIRoute } from "astro";
import { renderCvPdf } from "../../lib/cv-pdf";
import photo from "../../assets/profile.jpg?inline";

// Static endpoint: the CV is rendered from src/data/cv.ts at build time and served as
// /pdfs/nikolai-emil-damm-cv.pdf, so it can never drift behind the deployed site.
export const GET: APIRoute = async () => {
  const pdf = await renderCvPdf({ photo, updatedAt: new Date() });
  return new Response(new Uint8Array(pdf), { headers: { "Content-Type": "application/pdf" } });
};
