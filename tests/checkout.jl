using Test, LibGit2
pushfirst!(LOAD_PATH, joinpath(@__DIR__, ".."))
using Kip

# A repository with one file and one commit
function repository(dir)
  repo = LibGit2.init(dir)
  write(joinpath(dir, "main.jl"), "x = 1\n")
  LibGit2.add!(repo, "main.jl")
  me = LibGit2.Signature("Kip", "kip@example.com", round(Int, time()), 0)
  LibGit2.commit(repo, "first"; author=me, committer=me)
  repo
end

@testset "checkout" begin
  # Snapshots go into a folder of their own, not into ~/.kip/refs
  refs = Kip.refs
  Core.eval(Kip, :(refs = $(mktempdir())))
  key = ("kip-test", "Checkout.jl", nothing)
  try
    @testset "a package keeps its folder when its repository changes" begin
      dir = mktempdir()
      repo = repository(dir)
      folder = Kip.checkout(repo, key...)
      # A repository with nothing to commit is loaded from a snapshot of its commit
      @test startswith(folder, Kip.refs)
      @test read(joinpath(folder, "main.jl"), String) == "x = 1\n"
      # An edit makes the repository dirty, so a first load now would come from its working tree
      write(joinpath(dir, "main.jl"), "x = 2\n")
      @test Kip.checkout_repo(repo, key...) != folder
      # But this program already has the package, so it stays with the copy it has
      @test Kip.checkout(repo, key...) == folder
    end

    @testset "a package first loaded from its working tree stays there after a commit" begin
      delete!(Kip.checkouts, key)
      dir = mktempdir()
      repo = repository(dir)
      write(joinpath(dir, "main.jl"), "x = 2\n")
      folder = Kip.checkout(repo, key...)
      @test !startswith(folder, Kip.refs)
      LibGit2.add!(repo, "main.jl")
      me = LibGit2.Signature("Kip", "kip@example.com", round(Int, time()), 0)
      LibGit2.commit(repo, "second"; author=me, committer=me)
      @test startswith(Kip.checkout_repo(repo, key...), Kip.refs)
      @test Kip.checkout(repo, key...) == folder
    end
  finally
    delete!(Kip.checkouts, key)
    Core.eval(Kip, :(refs = $refs))
  end
end
