import { lazy, Suspense } from "react";
import { Skeleton } from "@/components/ui/skeleton";
import type { JsonEditorProps } from "./JsonEditor.impl";

export type { JsonEditorProps };

const JsonEditorImpl = lazy(() => import("./JsonEditor.impl"));

function JsonEditorSkeleton() {
  return (
    <Skeleton
      className="w-full rounded-md border"
      style={{ minHeight: "160px" }}
      aria-label="Loading editor…"
    />
  );
}

export function JsonEditor(props: JsonEditorProps) {
  return (
    <Suspense fallback={<JsonEditorSkeleton />}>
      <JsonEditorImpl {...props} />
    </Suspense>
  );
}
