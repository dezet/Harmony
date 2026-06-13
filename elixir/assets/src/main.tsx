import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { AppRoutes } from "@/App";
import { AppProviders } from "@/providers/AppProviders";
import "./index.css";

// import.meta.env.BASE_URL is "/app/" in Phases 0-2, "/" after Phase 3.
const basename = import.meta.env.BASE_URL.replace(/\/$/, "");

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AppProviders>
      <BrowserRouter basename={basename}>
        <AppRoutes />
      </BrowserRouter>
    </AppProviders>
  </StrictMode>,
);
