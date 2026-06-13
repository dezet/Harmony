import { Component, type ReactNode } from "react";

interface Props {
  children: ReactNode;
}
interface State {
  error: Error | null;
}

// React requires a class component for error boundaries.
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  render() {
    if (this.state.error) {
      return (
        <div className="p-6">
          <h1 className="text-xl font-semibold text-destructive">Something went wrong</h1>
          <pre className="mt-2 text-sm">{this.state.error.message}</pre>
        </div>
      );
    }
    return this.props.children;
  }
}
