import type { APIRoute } from "astro";
import sharp from "sharp";
import { renderCvPdf } from "../../lib/cv-pdf";
import photoDataUri from "../../assets/profile.jpg?inline";

// The portrait fills a 92pt circle, so a 320px square is all the PDF can show of it.
const PHOTO_SIZE = 320;

// Static endpoint: the CV is rendered from src/data/cv.ts at build time and served as
// /pdfs/nikolai-emil-damm-cv.pdf, so it can never drift behind the deployed site.
export const GET: APIRoute = async () => {
  const original = Buffer.from(photoDataUri.slice(photoDataUri.indexOf(",") + 1), "base64");
  const photo = await sharp(original)
    .rotate()
    .resize(PHOTO_SIZE, PHOTO_SIZE, { fit: "cover" })
    .jpeg({ quality: 85 })
    .toBuffer();
  const pdf = await renderCvPdf({ photo });
  return new Response(new Uint8Array(pdf), { headers: { "Content-Type": "application/pdf" } });
};
