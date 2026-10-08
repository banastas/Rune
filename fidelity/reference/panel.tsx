// A typed React panel, generated for the fidelity harness.
import { useState, type ReactNode } from "react";

interface PanelProps<T> {
  title: string;
  items: T[];
  render: (item: T) => ReactNode;
  footer?: ReactNode;
}

export function Panel<T extends { id: string }>({ title, items, render, footer }: PanelProps<T>) {
  const [open, setOpen] = useState<boolean>(true);
  const count: number = items.length;

  return (
    <section className="panel" aria-expanded={open}>
      <header onClick={() => setOpen(!open)}>
        <h3>{title}</h3>
        <span className="count">{count} items</span>
      </header>
      {open && (
        <div className="body">
          {items.map((item) => (
            <div key={item.id} className="row">
              {render(item)}
            </div>
          ))}
        </div>
      )}
      {footer ?? <footer>Nothing more.</footer>}
    </section>
  );
}

export const EmptyPanel = (): JSX.Element => <Panel title="Empty" items={[]} render={() => null} />;
