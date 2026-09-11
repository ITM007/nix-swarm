# A file whose name suggests credential material must never be indexed.

{ ... }:
{
  services.example.cookie = "do-not-serve";
}
