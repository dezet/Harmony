import { QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { queryClient } from "@/lib/queryClient";
import { useDashboardChannel } from "@/lib/socket";
import { ErrorBoundary } from "@/components/ErrorBoundary";
import { Toaster } from "@/components/ui/sonner";

function ChannelBridge({ children }: { children: ReactNode }) {
  useDashboardChannel(queryClient);
  return <>{children}</>;
}

export function AppProviders({ children }: { children: ReactNode }) {
  return (
    <ErrorBoundary>
      <QueryClientProvider client={queryClient}>
        <ChannelBridge>{children}</ChannelBridge>
        <Toaster />
      </QueryClientProvider>
    </ErrorBoundary>
  );
}
