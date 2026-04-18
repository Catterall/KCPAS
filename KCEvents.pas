unit KCEvents;
{
  KCEvents.pas

  General event signatures for the KCPAS units,
  such as logging and error handling.
}
interface

uses
  SysUtils;

type
  TOnLog = procedure(const aSentBy, aMessage: string) of object;
  TOnException = procedure(const aRaisedBy: string; aException: Exception) of object;

implementation

end.
