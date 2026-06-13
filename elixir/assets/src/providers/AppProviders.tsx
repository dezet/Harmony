import { QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { queryClient } from "@/lib/queryClient";
import { DashboardConnectionProvider, useDashboardConnection } from "@/lib/dashboardConnection";
import { useDashboardChannel } from "@/lib/socket";
import { ErrorBoundary } from "@/components/ErrorBoundary";
import { ThemeProvider } from "@/components/theme/ThemeProvider";
import { Toaster } from "@/components/ui/sonner";

function ChannelBridge({ children }: { children: ReactNode }) {
  const { setStatus } = useDashboardConnection();
  useDashboardChannel(queryClient, setStatus);
  return <>{children}</>;
}

export function AppProviders({ children }: { children: ReactNode }) {
  return (
    <ErrorBoundary>
      <ThemeProvider>
        <QueryClientProvider client={queryClient}>
          <DashboardConnectionProvider>
            <ChannelBridge>{children}</ChannelBridge>
          </DashboardConnectionProvider>
          <Toaster />
        </QueryClientProvider>
      </ThemeProvider>
    </ErrorBoundary>
  );
}
