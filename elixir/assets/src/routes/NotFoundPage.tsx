import { useEffect } from "react";
import { Link } from "react-router-dom";

export function NotFoundPage() {
  useEffect(() => {
    document.title = "Nie znaleziono strony — Harmony";
  }, []);

  return (
    <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3 text-center">
      <p className="font-mono text-5xl font-semibold text-muted-foreground">404</p>
      <h1 className="text-title">Nie znaleziono strony</h1>
      <p className="text-sm text-muted-foreground">Strona nie istnieje albo została przeniesiona.</p>
      <Link to="/" className="text-sm text-primary underline underline-offset-4">
        Wróć do Centrum spraw
      </Link>
    </div>
  );
}
