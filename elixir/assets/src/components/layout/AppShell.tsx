import { useState } from "react";
import { Dialog } from "@base-ui/react/dialog";
import { Menu } from "lucide-react";
import { Outlet } from "react-router-dom";
import { Breadcrumbs } from "@/components/layout/Breadcrumbs";
import { Sidebar } from "@/components/layout/Sidebar";

// Shell of layout A (spec §4.1, §4.5): sidebar 218 px, 185 px in 851–1150 px,
// below 851 px a slide-out panel behind the hamburger.

function MobileNav() {
  const [open, setOpen] = useState(false);

  return (
    <Dialog.Root open={open} onOpenChange={setOpen}>
      <Dialog.Trigger
        aria-label="Otwórz menu"
        className="-ml-1.5 inline-flex shrink-0 rounded-[7px] p-1.5 text-foreground min-[851px]:hidden"
      >
        <Menu aria-hidden className="size-[18px]" strokeWidth={1.6} />
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-40 bg-black/30 transition-opacity duration-200 data-ending-style:opacity-0 data-starting-style:opacity-0 motion-reduce:transition-none min-[851px]:hidden" />
        <Dialog.Popup className="fixed inset-y-0 left-0 z-50 w-[83%] overflow-y-auto shadow-[20px_0_70px_#0005] outline-none transition-transform duration-200 ease-[ease] data-ending-style:-translate-x-full data-starting-style:-translate-x-full motion-reduce:transition-none min-[601px]:w-3/4 min-[851px]:hidden">
          <Dialog.Title className="sr-only">Menu nawigacji</Dialog.Title>
          <Dialog.Close className="sr-only rounded-[7px] bg-card px-3 py-2 text-xs text-foreground focus:not-sr-only focus:absolute focus:top-3 focus:right-3">
            Zamknij menu
          </Dialog.Close>
          <Sidebar className="min-h-full" onNavigate={() => setOpen(false)} />
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export function AppShell() {
  return (
    <div className="flex h-dvh bg-background text-foreground">
      <a
        href="#main"
        className="sr-only rounded-[7px] bg-card p-3 text-foreground focus:not-sr-only focus:fixed focus:top-2.5 focus:left-5 focus:z-50"
      >
        Przejdź do treści
      </a>
      <Sidebar className="hidden w-[185px] shrink-0 overflow-y-auto border-r min-[851px]:flex min-[1151px]:w-[218px]" />
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-[50px] shrink-0 items-center gap-[7px] border-b bg-card px-[13px] min-[601px]:px-[22px] min-[851px]:h-[58px] min-[1151px]:px-8">
          <MobileNav />
          <Breadcrumbs />
        </header>
        <main id="main" tabIndex={-1} className="min-w-0 flex-1 overflow-y-auto outline-none">
          <div className="mx-auto w-full max-w-[1740px] px-4 py-[22px] min-[601px]:px-[22px] min-[601px]:py-[25px] min-[1151px]:p-8">
            <Outlet />
          </div>
        </main>
      </div>
    </div>
  );
}
