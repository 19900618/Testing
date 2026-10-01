import type { NextConfig } from "next";

// The pages that used to sit at the root moved under /toolkit when the home page
// became the workspace picker. Old bookmarks and shared links (query string
// included) land on the same page. The journey board was at "/", which is now the
// picker, so it has no redirect; it lives at /toolkit.
const MOVED = ["journey-flow", "cso", "cso-ugke", "collections", "capacity", "mason"];

const nextConfig: NextConfig = {
  async redirects() {
    return MOVED.map((p) => ({
      source: `/${p}/:rest*`,
      destination: `/toolkit/${p}/:rest*`,
      permanent: false,
    }));
  },
};

export default nextConfig;
