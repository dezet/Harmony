import { Link } from "react-router-dom";

export function NotFoundPage() {
  return (
    <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3 text-center">
      <p className="font-mono text-5xl font-semibold text-muted-foreground">404</p>
      <h1 className="text-xl font-medium">Page not found</h1>
      <p className="text-sm text-muted-foreground">
        The page you are looking for does not exist or has moved.
      </p>
      <Link to="/" className="text-sm underline underline-offset-4 hover:text-foreground">
        Back to Overview
      </Link>
    </div>
  );
}
