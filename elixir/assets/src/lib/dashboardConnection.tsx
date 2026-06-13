/* eslint-disable react-refresh/only-export-components */
import {
  createContext,
  useContext,
  useMemo,
  useState,
  type Dispatch,
  type ReactNode,
  type SetStateAction,
} from "react";

export type DashboardConnectionStatus = "connecting" | "live" | "reconnecting" | "offline";

interface DashboardConnectionValue {
  status: DashboardConnectionStatus;
  setStatus: Dispatch<SetStateAction<DashboardConnectionStatus>>;
}

const DashboardConnectionContext = createContext<DashboardConnectionValue | undefined>(undefined);

export function DashboardConnectionProvider({
  children,
  initialStatus = "connecting",
}: {
  children: ReactNode;
  initialStatus?: DashboardConnectionStatus;
}) {
  const parent = useContext(DashboardConnectionContext);
  const [status, setStatus] = useState<DashboardConnectionStatus>(initialStatus);
  const value = useMemo(() => ({ status, setStatus }), [status]);

  if (parent) return <>{children}</>;
  return (
    <DashboardConnectionContext.Provider value={value}>
      {children}
    </DashboardConnectionContext.Provider>
  );
}

export function useDashboardConnection(): DashboardConnectionValue {
  const value = useContext(DashboardConnectionContext);
  if (!value) {
    throw new Error("useDashboardConnection must be used within DashboardConnectionProvider");
  }
  return value;
}
