import { useIsFetching } from "@tanstack/react-query";
import { Badge } from "@/components/ui/badge";
import { DASHBOARD_KEY } from "@/lib/queryClient";

// "Live" once we have data; "Connecting…" while the first fetch/join is in flight.
export function ConnectionStatus({ hasData }: { hasData: boolean }) {
  const fetching = useIsFetching({ queryKey: DASHBOARD_KEY });
  if (hasData) return <Badge variant="secondary">Live</Badge>;
  return <Badge variant="outline">{fetching ? "Connecting…" : "Offline"}</Badge>;
}
