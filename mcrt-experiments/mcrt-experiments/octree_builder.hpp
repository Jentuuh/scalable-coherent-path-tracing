#pragma once
#include "octree_node.hpp"
#include "scene.hpp"
#include <stack>
#include <memory>
#include <string>

namespace mcrt {
	class OctreeBuilder
	{
	public:
		OctreeBuilder(int maxDepth, int octreeTextureRes, Scene& sceneObject);
		OctreeBuilder(std::string loadOctreePath);

		void saveOctreeToFile(std::string filePath);
		void writeGPUOctreeToTxtFile(std::string filePath);
		glm::ivec3 getTextureDimensions() { return currentCoord; };
		std::vector<float>& getOctree() { return gpuOctree; };

		void increaseProgress(int reportDepthLevel);

	private:
		std::unique_ptr<OctreeNode> root;
		std::stack<glm::vec3> parentCoordStack;
		std::vector<float> gpuOctree;
		glm::ivec3 currentCoord; // Maintains which indirection grid we are currently at (how many nodes we have already inserted (currentX, currentY, currentZ))
		float progress;
		int numNodes;
	};
}

