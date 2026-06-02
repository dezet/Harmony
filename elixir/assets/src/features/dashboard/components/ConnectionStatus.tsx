import { Badge } from "@/components/ui/badge";
import {
  useDashboardConnection,
  type DashboardConnectionStatus,
} from "@/lib/dashboardConnection";

const statusLabels: Record<DashboardConnectionStatus, string> = {
  connecting: "Connecting…",
  live: "Live",
  reconnecting: "Reconnecting…",
  offline: "Offline",
};

export function ConnectionStatus() {
  const { status } = useDashboardConnection();
  const variant =
    status === "live" ? "secondary" : status === "offline" ? "destructive" : "outline";

  return <Badge variant={variant}>{statusLabels[status]}</Badge>;
}
