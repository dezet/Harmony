import { Component, type ReactNode } from "react";

interface Props {
  children: ReactNode;
}
interface State {
  error: Error | null;
}

// React requires a class component for error boundaries. It sits outside the
// router, so the way back is a plain link. Only the message is shown, never
// the stack trace.
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  render() {
    if (this.state.error) {
      return (
        <main className="grid min-h-screen place-items-center bg-background p-6 text-foreground">
          <div role="alert" className="grid max-w-md justify-items-start gap-3 rounded-[10px] border bg-card p-[23px]">
            <h1 className="text-title">Coś poszło nie tak</h1>
            <p className="text-xs leading-[1.6] text-muted-foreground">
              Widok nie mógł zostać wyświetlony. Odśwież stronę albo wróć do Centrum spraw.
            </p>
            <p className="text-[11px] text-muted-foreground">Szczegóły: {this.state.error.message}</p>
            <a href="/" className="text-xs font-[550] text-primary underline underline-offset-4">
              Wróć do Centrum spraw
            </a>
          </div>
        </main>
      );
    }
    return this.props.children;
  }
}
