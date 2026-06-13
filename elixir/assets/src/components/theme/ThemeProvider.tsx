import { ThemeProvider as NextThemesProvider } from "next-themes";
import type { ReactNode } from "react";

// Studio direction: light by default, dark as an explicit toggle (class on <html>).
export function ThemeProvider({ children }: { children: ReactNode }) {
  return (
    <NextThemesProvider
      attribute="class"
      defaultTheme="light"
      enableSystem={false}
      disableTransitionOnChange
    >
      {children}
    </NextThemesProvider>
  );
}
