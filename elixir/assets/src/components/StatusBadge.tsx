import { Badge } from "@/components/ui/badge";

const variantByStatus: Record<string, "secondary" | "destructive" | "outline"> = {
  completed: "secondary",
  failed: "destructive",
  blocked: "destructive",
  running: "outline",
  queued: "outline",
};

export function StatusBadge({ status }: { status: string }) {
  return <Badge variant={variantByStatus[status] ?? "outline"}>{status}</Badge>;
}
